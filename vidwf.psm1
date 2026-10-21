#requires -Version 7.0
<#
    vidwf - workflow de video das cameras de acao (GoPro Session 5 / Insta360)

    Importar:   Import-Module 'D:\Documents\Projetos\Video Workflow\vidwf.psm1' -Force
#>

$script:VwfConfig     = $null
$script:VwfConfigPath = $null

#region infraestrutura ------------------------------------------------------

function Import-VwfConfig {
    <#
    .SYNOPSIS
        Carrega (ou recarrega) o vidwf.config.psd1.
    #>
    [CmdletBinding()]
    param(
        [string]$Path
    )

    if (-not $Path) {
        $Path = if ($script:VwfConfigPath) { $script:VwfConfigPath }
                else { Join-Path $PSScriptRoot 'vidwf.config.psd1' }
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Arquivo de configuracao nao encontrado: $Path"
    }

    $cfg  = Import-PowerShellDataFile -LiteralPath $Path
    $raiz = Split-Path (Resolve-Path -LiteralPath $Path).Path -Parent

    # Caminhos relativos em Paths sao resolvidos a partir da pasta do config,
    # para que o preset possa viajar junto com o modulo no repositorio.
    foreach ($k in @($cfg.Paths.Keys)) {
        $v = $cfg.Paths[$k]
        if ($v -and -not [System.IO.Path]::IsPathRooted($v)) {
            $cfg.Paths[$k] = Join-Path $raiz $v
        }
    }

    $script:VwfConfig     = $cfg
    $script:VwfConfigPath = (Resolve-Path -LiteralPath $Path).Path
    $script:VwfConfig
}

function Get-VwfConfig {
    [CmdletBinding()]
    param()
    if (-not $script:VwfConfig) { Import-VwfConfig | Out-Null }
    $script:VwfConfig
}

function Test-VwfTools {
    <#
    .SYNOPSIS
        Verifica se mp4_merge, Gyroflow, ffmpeg e ffprobe estao acessiveis.
    #>
    [CmdletBinding()]
    param()
    $cfg = Get-VwfConfig
    foreach ($kv in $cfg.Tools.GetEnumerator()) {
        $cmd = Get-Command $kv.Value -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Ferramenta = $kv.Key
            Comando    = $kv.Value
            Encontrada = [bool]$cmd
            Caminho    = $cmd.Source
        }
    }
}

function Get-VwfDuration {
    <#
    .SYNOPSIS
        Duracao do arquivo em segundos, via ffprobe.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $cfg = Get-VwfConfig
    $out = & $cfg.Tools.FFprobe -v error -show_entries format=duration -of csv=p=0 -i $Path 2>$null
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    [double]($out | Select-Object -First 1)
}

function Test-VwfMerge {
    <#
    .SYNOPSIS
        Confere um merge comparando duracao E tamanho do resultado com a soma
        das partes. Devolve um objeto com o veredito e os numeros.
    .DESCRIPTION
        A duracao sozinha nao pega um merge truncado: se o stbl foi escrito
        inteiro mas o mdat ficou pela metade, o arquivo "dura" o esperado e
        falha no meio. O tamanho pega esse caso.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Result,
        [Parameter(Mandatory)][System.IO.FileInfo[]]$Parts
    )

    $cfg = Get-VwfConfig
    $tol = $cfg.Tolerance

    $durEsperada = ($Parts | ForEach-Object { Get-VwfDuration $_.FullName } | Measure-Object -Sum).Sum
    $tamEsperado = ($Parts | Measure-Object Length -Sum).Sum

    $item      = Get-Item -LiteralPath $Result
    $durObtida = Get-VwfDuration $Result
    $tamObtido = $item.Length

    $tolDur = $tol.DurationSec + ($tol.DurationPart * $Parts.Count)
    $okDur  = $durObtida -and $durEsperada -and ([math]::Abs($durObtida - $durEsperada) -le $tolDur)

    # O container do resultado tem overhead proprio (stbl refeito, stco -> co64),
    # entao a comparacao e por percentual, nao exata.
    $difPct = if ($tamEsperado -gt 0) { 100 * [math]::Abs($tamObtido - $tamEsperado) / $tamEsperado } else { 100 }
    $okTam  = $difPct -le $tol.SizePercent

    [pscustomobject]@{
        Arquivo          = $item.Name
        DuracaoEsperada  = $durEsperada
        DuracaoObtida    = $durObtida
        DuracaoOk        = $okDur
        TamanhoEsperado  = $tamEsperado
        TamanhoObtido    = $tamObtido
        DesvioTamanhoPct = [math]::Round($difPct, 3)
        TamanhoOk        = $okTam
        Ok               = ($okDur -and $okTam)
    }
}

function Write-VwfMergeCheck {
    <#
    .SYNOPSIS
        Imprime o resultado de Test-VwfMerge em uma linha (ou um aviso).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][psobject]$Check, [string]$Indent = '')

    if ($Check.Ok) {
        Write-Host ("{0}OK: {1} - {2:n1}s, {3:n2} GB (desvio {4:n3}%)" -f
            $Indent, $Check.Arquivo, $Check.DuracaoObtida,
            ($Check.TamanhoObtido / 1GB), $Check.DesvioTamanhoPct) -ForegroundColor Green
        return
    }

    $motivos = @()
    if (-not $Check.DuracaoOk) {
        $motivos += ("duracao esperada {0:n1}s, obtida {1:n1}s" -f $Check.DuracaoEsperada, $Check.DuracaoObtida)
    }
    if (-not $Check.TamanhoOk) {
        $motivos += ("tamanho esperado {0:n2} GB, obtido {1:n2} GB (desvio {2:n3}%)" -f
            ($Check.TamanhoEsperado / 1GB), ($Check.TamanhoObtido / 1GB), $Check.DesvioTamanhoPct)
    }
    Write-Warning ("{0}: {1}. Originais preservados." -f $Check.Arquivo, ($motivos -join '; '))
}

function Get-VwfFreeSpace {
    <#
    .SYNOPSIS
        Espaco livre, em bytes, do volume que contem o caminho informado.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $raiz = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path)
    if (-not $raiz) { $raiz = [System.IO.Path]::GetPathRoot($Path) }

    try {
        ([System.IO.DriveInfo]::new($raiz)).AvailableFreeSpace
    } catch {
        Write-Warning "Nao foi possivel medir o espaco livre em $raiz."
        $null
    }
}

function Test-VwfSpace {
    <#
    .SYNOPSIS
        Verifica se ha espaco para gravar Required bytes no destino, com folga.
    .PARAMETER Required
        Bytes que serao escritos.
    .PARAMETER MarginPercent
        Folga sobre o necessario. Padrao: SpaceMarginPercent do config.
    .OUTPUTS
        Objeto com Ok, LivreGB, NecessarioGB e FaltaGB.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Required,
        [double]$MarginPercent = -1
    )

    $cfg = Get-VwfConfig
    if ($MarginPercent -lt 0) { $MarginPercent = $cfg.SpaceMarginPercent }

    $livre     = Get-VwfFreeSpace -Path $Path
    $comFolga  = $Required * (1 + ($MarginPercent / 100))

    [pscustomobject]@{
        Caminho       = $Path
        LivreGB       = if ($null -ne $livre) { [math]::Round($livre / 1GB, 2) } else { $null }
        NecessarioGB  = [math]::Round($comFolga / 1GB, 2)
        FaltaGB       = if ($null -ne $livre) { [math]::Round([math]::Max([double]0, [double]($comFolga - $livre)) / 1GB, 2) } else { $null }
        # Sem leitura de espaco, nao bloqueia: so avisa e deixa seguir.
        Ok            = ($null -eq $livre) -or ($livre -ge $comFolga)
        Medido        = ($null -ne $livre)
    }
}

function Assert-VwfSpace {
    <#
    .SYNOPSIS
        Interrompe a operacao se nao houver espaco suficiente no destino.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$Required,
        [string]$Operacao = 'a operacao',
        [switch]$IgnoreSpace
    )

    $esp = Test-VwfSpace -Path $Path -Required $Required

    if (-not $esp.Medido) {
        Write-Warning 'Espaco livre nao pode ser medido; seguindo sem verificar.'
        return $esp
    }

    $msg = "{0}: precisa de ~{1} GB (com folga), ha {2} GB livres em {3}" -f
           $Operacao, $esp.NecessarioGB, $esp.LivreGB, [System.IO.Path]::GetPathRoot($Path)

    if ($esp.Ok) {
        Write-Host "Espaco OK - $msg." -ForegroundColor DarkGray
        return $esp
    }

    if ($IgnoreSpace) {
        Write-Warning "$msg. Faltam ~$($esp.FaltaGB) GB. Prosseguindo por causa de -IgnoreSpace."
        return $esp
    }

    throw "Espaco insuficiente. $msg. Faltam ~$($esp.FaltaGB) GB. Libere espaco ou use -IgnoreSpace."
}

function Test-VwfFileReady {
    <#
    .SYNOPSIS
        Diz se o arquivo nao esta aberto por outro processo (ex.: um mp4_merge
        rodando em outra aba do terminal ainda escrevendo nele).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Dispose()
        $true
    } catch {
        $false
    }
}

function Get-VwfFrameRate {
    <#
    .SYNOPSIS
        Taxa de quadros do video, via ffprobe. $null se nao der para ler.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $cfg = Get-VwfConfig
    $out = & $cfg.Tools.FFprobe -v error -select_streams v:0 `
            -show_entries stream=avg_frame_rate -of csv=p=0 -i $Path 2>$null
    $txt = ($out | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }

    # ffprobe devolve fracao, ex.: 60000/1001
    if ($txt -match '^(\d+)\s*/\s*(\d+)$') {
        $den = [double]$Matches[2]
        if ($den -eq 0) { return $null }
        return [double]$Matches[1] / $den
    }
    try { [double]$txt } catch { $null }
}

function Get-VwfCreationTime {
    <#
    .SYNOPSIS
        Horario de gravacao do arquivo (metadado do container; cai para LastWriteTime).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $cfg = Get-VwfConfig
    $out = & $cfg.Tools.FFprobe -v error -show_entries format_tags=creation_time -of csv=p=0 -i $Path 2>$null
    $txt = ($out | Select-Object -First 1)

    if (-not [string]::IsNullOrWhiteSpace($txt)) {
        $dt = [datetime]::MinValue
        $ok = [datetime]::TryParse(
            $txt,
            [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref]$dt)
        if ($ok) { return $dt }
    }

    (Get-Item -LiteralPath $Path).LastWriteTimeUtc
}

#endregion

#region projeto -------------------------------------------------------------

function Select-VwfProject {
    <#
    .SYNOPSIS
        Abre o seletor de pastas na raiz dos projetos e devolve a pasta escolhida.
    .PARAMETER New
        Nome de uma pasta nova a criar sob a raiz, sem abrir a janela.
    #>
    [CmdletBinding()]
    param(
        [string]$New,
        [string]$Root
    )

    $cfg = Get-VwfConfig
    if (-not $Root) { $Root = $cfg.Paths.ProjectsRoot }

    if ($New) {
        $path = Join-Path $Root $New
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
        return (Resolve-Path -LiteralPath $path).Path
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description         = 'Selecione a pasta do passeio'
    $dlg.SelectedPath        = $Root
    $dlg.ShowNewFolderButton = $true

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        throw 'Nenhuma pasta selecionada.'
    }
    $dlg.SelectedPath
}

function Get-VwfMaster {
    <#
    .SYNOPSIS
        Localiza o arquivo final (master) do projeto, qualquer que seja a
        extensao. $null se nao houver.
    .DESCRIPTION
        A extensao varia: com preserve_other_tracks ligado no preset, a saida do
        Gyroflow e .mov, e o master herda isso.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Name
    )

    $cfg = Get-VwfConfig
    if (-not $Name) { $Name = Split-Path $Project -Leaf }

    Get-ChildItem -LiteralPath $Project -File -Filter "$Name.*" -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $Name } |
        Sort-Object Length -Descending | Select-Object -First 1
}

function Get-VwfWorkDir {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)

    $cfg  = Get-VwfConfig
    $work = Join-Path $Project $cfg.WorkDir
    if (-not (Test-Path -LiteralPath $work)) {
        New-Item -ItemType Directory -Path $work -Force | Out-Null
    }
    $work
}

#endregion

#region hilights ------------------------------------------------------------

function script:Find-VwfBox {
    <#
        Localiza uma box ISOBMFF por tipo dentro de um intervalo do arquivo.
        Devolve o inicio e o fim do conteudo (sem o cabecalho).
    #>
    param(
        [System.IO.Stream]$Stream,
        [long]$From,
        [long]$To,
        [string]$Type
    )

    $pos = $From
    $hdr = New-Object byte[] 16

    while ($pos + 8 -le $To) {
        $Stream.Position = $pos
        if ($Stream.Read($hdr, 0, 8) -ne 8) { break }

        $size = ([int64]$hdr[0] -shl 24) + ([int64]$hdr[1] -shl 16) +
                ([int64]$hdr[2] -shl 8)  +  [int64]$hdr[3]
        $tipo   = [System.Text.Encoding]::ASCII.GetString($hdr, 4, 4)
        $cabeca = 8

        if ($size -eq 1) {
            # size estendido de 64 bits
            if ($Stream.Read($hdr, 8, 8) -ne 8) { break }
            $size = [int64]0
            for ($i = 8; $i -lt 16; $i++) { $size = ($size -shl 8) + [int64]$hdr[$i] }
            $cabeca = 16
        } elseif ($size -eq 0) {
            $size = $To - $pos   # ultima box, vai ate o fim
        }

        if ($size -lt $cabeca) { break }

        if ($tipo -eq $Type) {
            return [pscustomobject]@{
                Inicio = $pos + $cabeca
                Fim    = [math]::Min($pos + $size, $To)
            }
        }
        $pos += $size
    }
    $null
}

function Get-VwfHighlights {
    <#
    .SYNOPSIS
        Le as HiLight tags de um arquivo GoPro. Devolve os offsets em ms.
    .DESCRIPTION
        As tags ficam em /moov/udta/HMMT: um uint32 com a quantidade, seguido de
        um uint32 por tag com o offset em milissegundos (big endian). Nao e uma
        trilha, por isso nao sobrevive a reencodagem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $moov = Find-VwfBox -Stream $fs -From 0 -To $fs.Length -Type 'moov'
        if (-not $moov) { return @() }

        $udta = Find-VwfBox -Stream $fs -From $moov.Inicio -To $moov.Fim -Type 'udta'
        if (-not $udta) { return @() }

        $hmmt = Find-VwfBox -Stream $fs -From $udta.Inicio -To $udta.Fim -Type 'HMMT'
        if (-not $hmmt) { return @() }

        $tam = $hmmt.Fim - $hmmt.Inicio
        if ($tam -lt 4) { return @() }

        $buf = New-Object byte[] $tam
        $fs.Position = $hmmt.Inicio
        [void]$fs.Read($buf, 0, $tam)

        $qtd = ([int64]$buf[0] -shl 24) + ([int64]$buf[1] -shl 16) +
               ([int64]$buf[2] -shl 8)  +  [int64]$buf[3]

        # A camera grava no maximo 100 tags; limita tambem pelo tamanho real.
        $cabem = [math]::Floor(($tam - 4) / 4)
        if ($qtd -gt $cabem) { $qtd = $cabem }
        if ($qtd -gt 100)    { $qtd = 100 }
        if ($qtd -le 0)      { return @() }

        $saida = New-Object System.Collections.Generic.List[int64]
        for ($i = 0; $i -lt $qtd; $i++) {
            $o = 4 + ($i * 4)
            $ms = ([int64]$buf[$o] -shl 24) + ([int64]$buf[$o+1] -shl 16) +
                  ([int64]$buf[$o+2] -shl 8) + [int64]$buf[$o+3]
            if ($ms -gt 0) { $saida.Add($ms) }
        }
        , ($saida | Sort-Object -Unique)
    } finally {
        $fs.Dispose()
    }
}

function Export-VwfHighlights {
    <#
    .SYNOPSIS
        Junta as HiLight tags de varias partes em um sidecar JSON, deslocando
        cada parte pela duracao acumulada das anteriores.
    .DESCRIPTION
        Necessario porque o mp4_merge preserva os metadados do PRIMEIRO arquivo
        apenas: as tags dos capitulos seguintes se perderiam na uniao.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo[]]$Parts,
        [Parameter(Mandatory)][string]$Destination,
        [string]$SourceName
    )

    $tags  = New-Object System.Collections.Generic.List[int64]
    $desl  = [double]0

    foreach ($p in $Parts) {
        foreach ($ms in (Get-VwfHighlights -Path $p.FullName)) {
            $tags.Add([int64]($ms + ($desl * 1000)))
        }
        $d = Get-VwfDuration $p.FullName
        if ($d) { $desl += $d }
    }

    if ($tags.Count -eq 0) { return 0 }

    $ordenadas = @($tags | Sort-Object -Unique)
    [pscustomobject]@{
        source       = $(if ($SourceName) { $SourceName } else { $Parts[0].Name })
        extracted_at = (Get-Date).ToString('o')
        count        = $ordenadas.Count
        hilights_ms  = $ordenadas
        hilights_hms = @($ordenadas | ForEach-Object {
            [timespan]::FromMilliseconds($_).ToString('hh\:mm\:ss\.fff')
        })
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Destination -Encoding UTF8

    $ordenadas.Count
}

function Add-VwfChapters {
    <#
    .SYNOPSIS
        Grava as HiLight tags de volta no video, como capitulos.
    .DESCRIPTION
        Capitulos aparecem na linha do tempo dos players. Nao sao a box HMMT
        original (que o ffmpeg nao escreve), mas servem ao mesmo proposito e sao
        lidos por mais programas. O video nao e reencodado (-codec copy).

        Um capitulo "Inicio" em 0 e sempre incluido porque o muxer do ffmpeg
        force o primeiro capitulo para o inicio do arquivo; sem ele, a primeira
        HiLight seria deslocada para 0.
    .PARAMETER OutFile
        Grava em outro arquivo em vez de substituir o original.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Highlights,
        [string]$OutFile
    )

    $cfg = Get-VwfConfig
    if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo nao encontrado: $Path" }
    $src = Get-Item -LiteralPath $Path

    if (-not $Highlights) {
        $Highlights = Join-Path $src.DirectoryName "$($src.BaseName).hilights.json"
    }
    if (-not (Test-Path -LiteralPath $Highlights)) {
        Write-Warning "Sem sidecar de HiLights ($Highlights); nada a fazer."
        return
    }

    $dados = Get-Content -LiteralPath $Highlights -Raw -Encoding UTF8 | ConvertFrom-Json
    $marcas = @($dados.hilights_ms | Sort-Object -Unique | Where-Object { $_ -gt 0 })
    if (-not $marcas) { Write-Warning 'Sidecar sem marcas validas.'; return }

    $durMs = [int64](( Get-VwfDuration $src.FullName ) * 1000)
    $marcas = @($marcas | Where-Object { $_ -lt $durMs })
    if (-not $marcas) { Write-Warning 'Nenhuma marca cai dentro da duracao do video.'; return }

    # Inicios dos capitulos: 0 (contorno do muxer) + cada HiLight.
    $inicios = @(0) + $marcas
    $linhas  = New-Object System.Collections.Generic.List[string]
    $linhas.Add(';FFMETADATA1')

    for ($i = 0; $i -lt $inicios.Count; $i++) {
        $ini = [int64]$inicios[$i]
        $fim = if ($i -lt $inicios.Count - 1) { [int64]$inicios[$i+1] - 1 } else { $durMs }
        if ($fim -le $ini) { continue }
        $titulo = if ($i -eq 0) { 'Inicio' } else { "HiLight $i" }

        $linhas.Add('')
        $linhas.Add('[CHAPTER]')
        $linhas.Add('TIMEBASE=1/1000')
        $linhas.Add("START=$ini")
        $linhas.Add("END=$fim")
        $linhas.Add("title=$titulo")
    }

    $meta = Join-Path ([System.IO.Path]::GetTempPath()) "vidwf-chapters-$([guid]::NewGuid().ToString('N')).txt"
    $linhas -join "`n" | Set-Content -LiteralPath $meta -Encoding UTF8

    $substituir = -not $OutFile
    $destino    = if ($OutFile) { $OutFile }
                  else { Join-Path $src.DirectoryName "$($src.BaseName).chapters-tmp$($src.Extension)" }

    try {
        if (-not $PSCmdlet.ShouldProcess($src.Name, "Gravar $($marcas.Count) capitulo(s)")) { return }

        & $cfg.Tools.FFmpeg -hide_banner -loglevel error -y -i $src.FullName -i $meta `
            -map_metadata 1 -map_chapters 1 -codec copy $destino

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $destino)) {
            Write-Error 'ffmpeg falhou ao gravar os capitulos; arquivo original intacto.'
            return
        }

        # So substitui depois de conferir que a duracao bateu.
        $novaDur = Get-VwfDuration $destino
        $okDur   = $novaDur -and ([math]::Abs($novaDur * 1000 - $durMs) -le 1000)
        if (-not $okDur) {
            Write-Error ("Duracao divergente apos gravar capitulos ({0:n1}s vs {1:n1}s); original intacto." -f $novaDur, ($durMs / 1000))
            Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
            return
        }

        if ($substituir) {
            Move-Item -LiteralPath $destino -Destination $src.FullName -Force
            Write-Host "$($marcas.Count) capitulo(s) gravado(s) em $($src.Name)." -ForegroundColor Green
            Get-Item -LiteralPath $src.FullName
        } else {
            Write-Host "$($marcas.Count) capitulo(s) gravado(s) em $(Split-Path $destino -Leaf)." -ForegroundColor Green
            Get-Item -LiteralPath $destino
        }
    } finally {
        Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region cartao --------------------------------------------------------------

function Get-VwfCardInfo {
    <#
    .SYNOPSIS
        Identifica a camera pelo rotulo do volume do cartao.
    #>
    [CmdletBinding()]
    param([string]$Source)

    $cfg = Get-VwfConfig
    if (-not $Source) { $Source = $cfg.Paths.DefaultSource }

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Origem nao encontrada: $Source (o cartao esta inserido?)"
    }

    $letter = (Split-Path -Qualifier (Resolve-Path -LiteralPath $Source).Path).TrimEnd(':')
    $vol    = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
    $label  = $vol.FileSystemLabel

    $tag = if ($label -and $cfg.Cameras.ContainsKey($label)) { $cfg.Cameras[$label] }
           elseif ($label) { ($label -replace '[^\w]', '') }
           else { $cfg.DefaultCameraTag }

    [pscustomobject]@{
        Source      = (Resolve-Path -LiteralPath $Source).Path
        Drive       = "$letter`:"
        Label       = $label
        Tag         = $tag
        LivreGB     = if ($vol) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { $null }
        Mapeado     = [bool]($label -and $cfg.Cameras.ContainsKey($label))
    }
}

function Get-VwfCardClips {
    <#
    .SYNOPSIS
        Agrupa os arquivos do cartao por numero de video (GOPR0055 + GP010055 + ...).
    #>
    [CmdletBinding()]
    param([string]$Source)

    $card = Get-VwfCardInfo -Source $Source

    Get-ChildItem -LiteralPath $card.Source -File -Filter 'G*.MP4' |
        Where-Object { $_.Name -match '^(?<pfx>GOPR|GP\d{2})(?<num>\d{4})\.MP4$' } |
        Group-Object { [regex]::Match($_.Name, '^(?:GOPR|GP\d{2})(\d{4})\.MP4$').Groups[1].Value } |
        ForEach-Object {
            $partes = $_.Group | Sort-Object {
                if ($_.Name -like 'GOPR*') { 0 } else { [int]$_.Name.Substring(2, 2) }
            }
            [pscustomobject]@{
                Tag      = $card.Tag
                Numero   = $_.Name
                Partes   = $partes
                Arquivos = $partes.Name
                TamanhoGB = [math]::Round((($partes | Measure-Object Length -Sum).Sum) / 1GB, 2)
            }
        } | Sort-Object Numero
}

function Clear-VwfCardJunk {
    <#
    .SYNOPSIS
        Remove os .LRV e .THM do cartao.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param([string]$Source)

    $card  = Get-VwfCardInfo -Source $Source
    $lixo  = Get-ChildItem -LiteralPath $card.Source -File |
             Where-Object { $_.Extension -in '.LRV', '.THM' }

    if (-not $lixo) { Write-Verbose 'Nenhum .LRV/.THM encontrado.'; return }

    $gb = [math]::Round((($lixo | Measure-Object Length -Sum).Sum) / 1GB, 2)
    if ($PSCmdlet.ShouldProcess("$($lixo.Count) arquivos ($gb GB) em $($card.Source)", 'Remover LRV/THM')) {
        $lixo | Remove-Item -Force
        Write-Host "Removidos $($lixo.Count) arquivos auxiliares ($gb GB)." -ForegroundColor DarkGray
    }
}

function Import-VwfCard {
    <#
    .SYNOPSIS
        Une os capitulos de cada video do cartao e grava em <projeto>\work
        com o nome <TAG>_<NUMERO>.MP4.
    .PARAMETER DeleteSource
        Apaga os arquivos originais do cartao apos conferir a duracao do resultado.
    .EXAMPLE
        Import-VwfCard -Project $proj -DeleteSource
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Source,
        [string[]]$Numero,
        [switch]$DeleteSource,
        [switch]$CleanJunk,
        [switch]$IgnoreSpace,
        [switch]$NoHighlights,
        [switch]$Force
    )

    $cfg  = Get-VwfConfig
    $card = Get-VwfCardInfo -Source $Source
    $work = Get-VwfWorkDir -Project $Project

    if (-not $card.Mapeado) {
        Write-Warning "Rotulo do cartao '$($card.Label)' nao esta no mapa de cameras; usando a tag '$($card.Tag)'."
    }
    Write-Host "Cartao $($card.Drive) [$($card.Label)] -> tag $($card.Tag)" -ForegroundColor Cyan

    if ($CleanJunk) { Clear-VwfCardJunk -Source $card.Source }

    $clips = Get-VwfCardClips -Source $card.Source
    if ($Numero) { $clips = $clips | Where-Object Numero -in $Numero }
    if (-not $clips) { Write-Warning 'Nenhum video encontrado no cartao.'; return }

    # Soma apenas o que sera realmente escrito (ignora o que ja esta no destino).
    $aEscrever = $clips | Where-Object {
        $Force -or -not (Test-Path -LiteralPath (Join-Path $work "$($_.Tag)_$($_.Numero).MP4"))
    }
    if ($aEscrever) {
        $bytes = ($aEscrever.Partes | Measure-Object Length -Sum).Sum
        Assert-VwfSpace -Path $work -Required $bytes -IgnoreSpace:$IgnoreSpace `
            -Operacao "Importar $($aEscrever.Count) video(s) do cartao $($card.Tag)" | Out-Null
    }

    foreach ($clip in $clips) {
        $destino = Join-Path $work "$($clip.Tag)_$($clip.Numero).MP4"

        if ((Test-Path -LiteralPath $destino) -and -not $Force) {
            Write-Host "  $($clip.Tag)_$($clip.Numero): ja existe no destino, pulando." -ForegroundColor DarkYellow
            continue
        }

        $alvo = "$($clip.Numero) ($($clip.Partes.Count) parte(s), $($clip.TamanhoGB) GB) -> $(Split-Path $destino -Leaf)"
        if (-not $PSCmdlet.ShouldProcess($alvo, 'Unir capitulos')) { continue }

        Write-Host "  Unindo $($clip.Arquivos -join ', ')" -ForegroundColor Gray

        if ($clip.Partes.Count -eq 1) {
            Copy-Item -LiteralPath $clip.Partes[0].FullName -Destination $destino -Force
        } else {
            & $cfg.Tools.Mp4Merge $clip.Partes.FullName --out $destino
            if ($LASTEXITCODE -ne 0) { Write-Error "mp4_merge falhou no video $($clip.Numero)."; continue }
        }

        $check = Test-VwfMerge -Result $destino -Parts $clip.Partes
        $ok    = $check.Ok
        Write-VwfMergeCheck -Check $check -Indent '  '

        # As HiLight tags vivem no udta e nao sobrevivem a estabilizacao, nem a
        # uniao (o mp4_merge so herda os metadados do primeiro capitulo).
        # Extrai agora, enquanto os originais ainda existem.
        $nTags = 0
        if ($ok -and -not $NoHighlights) {
            $sidecar = Join-Path $work "$([System.IO.Path]::GetFileNameWithoutExtension($destino)).hilights.json"
            $nTags = Export-VwfHighlights -Parts $clip.Partes -Destination $sidecar `
                        -SourceName (Split-Path $destino -Leaf)
            if ($nTags) { Write-Host "    $nTags HiLight(s) salvos em $(Split-Path $sidecar -Leaf)" -ForegroundColor DarkGray }
        }

        if ($DeleteSource -and $ok) {
            if ($PSCmdlet.ShouldProcess("$($clip.Arquivos -join ', ') no cartao", 'Remover originais')) {
                $clip.Partes | Remove-Item -Force
            }
        }

        [pscustomobject]@{
            Numero   = $clip.Numero
            Tag      = $clip.Tag
            Arquivo  = $destino
            Duracao  = $check.DuracaoObtida
            TamanhoGB = [math]::Round($check.TamanhoObtido / 1GB, 2)
            HiLights = $nTags
            Conferiu = $ok
        }
    }
}

#endregion

#region estabilizacao -------------------------------------------------------

function Show-VwfPresetPaths {
    <#
    .SYNOPSIS
        Lista todo valor do preset que parece um caminho de arquivo/pasta.
    .DESCRIPTION
        Util para descobrir o que o Gyroflow gravou junto quando o preset foi
        salvo pela GUI com todas as opcoes marcadas.
    #>
    [CmdletBinding()]
    param([string]$Preset)

    $cfg = Get-VwfConfig
    if (-not $Preset) { $Preset = $cfg.Paths.Preset }
    if (-not (Test-Path -LiteralPath $Preset)) { throw "Preset nao encontrado: $Preset" }

    $json = Get-Content -LiteralPath $Preset -Raw -Encoding UTF8 | ConvertFrom-Json

    function Walk($node, $caminho) {
        if ($node -is [string]) {
            if ($node -match '^[A-Za-z]:[\\/]' -or $node -match '^[\\/]{2}') {
                [pscustomobject]@{ Chave = $caminho; Valor = $node }
            }
            return
        }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
            $i = 0
            foreach ($item in $node) { Walk $item "$caminho[$i]"; $i++ }
            return
        }
        if ($node -is [psobject] -and $node.PSObject.Properties) {
            foreach ($p in $node.PSObject.Properties) {
                Walk $p.Value ($(if ($caminho) { "$caminho.$($p.Name)" } else { $p.Name }))
            }
        }
    }

    Walk $json ''
}

function New-VwfCleanPreset {
    <#
    .SYNOPSIS
        Gera uma copia do preset sem os caminhos de saida que a GUI grava junto.
    .DESCRIPTION
        Quando um preset e salvo pela GUI com todas as opcoes marcadas, ele leva
        a pasta de saida em uso naquele momento. Depois disso, todo render feito
        com esse preset cai naquela pasta, independente da entrada e do diretorio
        atual. Esta funcao remove essas chaves em uma copia temporaria, deixando
        o preset original intacto.
    .OUTPUTS
        Caminho da copia limpa.
    #>
    [CmdletBinding()]
    param(
        [string]$Preset,
        [string]$Destination
    )

    $cfg = Get-VwfConfig
    if (-not $Preset) { $Preset = $cfg.Paths.Preset }
    if (-not (Test-Path -LiteralPath $Preset)) { throw "Preset nao encontrado: $Preset" }

    $json = Get-Content -LiteralPath $Preset -Raw -Encoding UTF8 | ConvertFrom-Json

    # Nomes de chave que carregam caminho de saida, em qualquer nivel.
    $padraoChave = '^(output_(folder|filename|path|file)|folder|filename|path|file)$'
    $removidas   = [System.Collections.Generic.List[string]]::new()

    function Scrub($node, $caminho) {
        if ($null -eq $node -or $node -is [string] -or $node -is [valuetype]) { return }

        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($item in $node) { Scrub $item $caminho }
            return
        }

        if (-not $node.PSObject.Properties) { return }

        foreach ($p in @($node.PSObject.Properties)) {
            $nome  = $p.Name
            $pleno = if ($caminho) { "$caminho.$nome" } else { $nome }

            $ehCaminho = ($p.Value -is [string]) -and
                         ($p.Value -match '^[A-Za-z]:[\\/]' -or $p.Value -match '^[\\/]{2}')

            if ($nome -match $padraoChave -and $ehCaminho) {
                $removidas.Add("$pleno = $($p.Value)")
                $node.PSObject.Properties.Remove($nome)
                continue
            }
            Scrub $p.Value $pleno
        }
    }

    Scrub $json ''

    if (-not $Destination) {
        $nome        = [System.IO.Path]::GetFileNameWithoutExtension($Preset)
        $Destination = Join-Path ([System.IO.Path]::GetTempPath()) "vidwf-$nome-limpo.gyroflow"
    }

    $json | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $Destination -Encoding UTF8

    if ($removidas.Count) {
        Write-Host "Preset: removidos $($removidas.Count) caminho(s) de saida para esta execucao:" -ForegroundColor DarkYellow
        $removidas | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }

    $Destination
}

function Invoke-VwfStabilize {
    <#
    .SYNOPSIS
        Estabiliza no Gyroflow todos os videos pendentes em <projeto>\work.
    .PARAMETER Parallel
        Numero de renders simultaneos (parametro -j do Gyroflow).
    .PARAMETER DeleteSource
        Apaga o arquivo unido apos a estabilizacao.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Preset,
        [int]$Parallel = 1,
        [string[]]$OutParams,
        [switch]$DeleteSource,
        [switch]$IgnoreSpace,
        [switch]$RawPreset,
        [double]$ExpectedFps = -1,
        [switch]$IgnoreFps,
        [switch]$StdoutProgress,
        [switch]$Force
    )

    $cfg  = Get-VwfConfig
    $work = Get-VwfWorkDir -Project $Project
    if (-not $Preset) { $Preset = $cfg.Paths.Preset }

    if (-not (Test-Path -LiteralPath $Preset)) { throw "Preset nao encontrado: $Preset" }

    # Mostra o preset em uso e o que ele decide sobre o container, porque uma
    # troca despercebida ali muda a extensao da saida.
    Write-Host "Preset: $Preset" -ForegroundColor DarkGray
    try {
        $pj  = Get-Content -LiteralPath $Preset -Raw -Encoding UTF8 | ConvertFrom-Json
        $pot = $pj.output.preserve_other_tracks
        if ($pot) {
            Write-Warning 'preserve_other_tracks esta ligado no preset: a saida sera .mov, nao .mp4.'
        }
    } catch {
        Write-Warning "Nao foi possivel ler o preset como JSON: $($_.Exception.Message)"
    }

    # Um preset salvo pela GUI costuma carregar a pasta de saida de entao, o que
    # faz o render cair sempre la. Usa uma copia sem esses caminhos.
    if (-not $RawPreset) { $Preset = New-VwfCleanPreset -Preset $Preset }

    $sufixo    = $cfg.StabSuffix
    $pendentes = Get-ChildItem -LiteralPath $work -File -Filter '*.MP4' |
        Where-Object { $_.BaseName -notlike "*$sufixo" } |
        Where-Object {
            # Extensao por padrao: com preserve_other_tracks o Gyroflow grava .mov.
            $Force -or -not (Get-ChildItem -LiteralPath $work -File -Filter "$($_.BaseName)$sufixo.*")
        } |
        Where-Object {
            # Evita pegar um arquivo que outra aba ainda esta escrevendo.
            if (Test-VwfFileReady $_.FullName) { $true }
            else { Write-Warning "$($_.Name) esta em uso por outro processo; sera ignorado nesta rodada."; $false }
        } | Sort-Object Name

    # O preset fixa o rolling shutter em funcao do fps, entao footage em outra
    # taxa sai com correcao errada. Separa esses arquivos em vez de processar.
    if ($ExpectedFps -lt 0) { $ExpectedFps = $cfg.ExpectedFps }
    if ($ExpectedFps -gt 0 -and $pendentes) {
        $divergentes = @()
        $pendentes = @($pendentes | Where-Object {
            $fps = Get-VwfFrameRate $_.FullName
            if ($null -eq $fps) { return $true }          # ilegivel: nao bloqueia
            if ([math]::Abs($fps - $ExpectedFps) -le 0.5) { return $true }
            $divergentes += [pscustomobject]@{ Nome = $_.Name; Fps = [math]::Round($fps, 2) }
            return [bool]$IgnoreFps
        })

        foreach ($d in $divergentes) {
            Write-Warning ("{0}: {1} fps, esperado {2}. {3}" -f $d.Nome, $d.Fps, $ExpectedFps,
                $(if ($IgnoreFps) { 'Processando assim mesmo (-IgnoreFps).' }
                  else { 'Fora desta rodada - use -Preset com um preset dessa taxa, ou -IgnoreFps.' }))
        }
    }

    if (-not $pendentes) {
        Write-Host 'Nada pendente para estabilizar.' -ForegroundColor DarkGray
        # A limpeza nao depende de ter renderizado agora: originais ja
        # estabilizados em rodadas anteriores tambem sao removidos.
        if ($DeleteSource) { Remove-VwfStabilizedSources -Project $Project }
        return
    }

    Write-Host "Estabilizando $($pendentes.Count) video(s):" -ForegroundColor Cyan
    $pendentes.Name | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    # O render do Gyroflow costuma sair perto do tamanho da entrada; o fator do
    # config ajusta isso (bitrate alto pode passar do original).
    $bytes = (($pendentes | Measure-Object Length -Sum).Sum) * $cfg.StabSizeFactor
    Assert-VwfSpace -Path $work -Required $bytes -IgnoreSpace:$IgnoreSpace `
        -Operacao "Estabilizar $($pendentes.Count) video(s)" | Out-Null

    if (-not $PSCmdlet.ShouldProcess("$($pendentes.Count) video(s) em $work", 'Gyroflow')) { return }

    # --stdout-progress duplica o progresso em milhares de linhas e enterra os
    # avisos do modulo, entao so entra se pedido.
    $gfArgs = @($pendentes.FullName) + @('--preset', $Preset, '-t', $sufixo)
    if ($StdoutProgress) { $gfArgs += '--stdout-progress' }
    if ($Parallel -gt 1) { $gfArgs += @('-j', "$Parallel") }
    if ($Force)          { $gfArgs += '-f' }
    if ($OutParams)      { $gfArgs += @('-p', ($OutParams -join ' ')) }

    # O Gyroflow e um app de GUI: chamado com '&', devolve o prompt na hora e
    # renderiza solto, o que faria a conferencia das saidas rodar cedo demais.
    # Start-Process -Wait aguarda o processo terminar de verdade.
    $exe = (Get-Command $cfg.Tools.Gyroflow -ErrorAction Stop).Source

    # Start-Process nao cita os argumentos; os caminhos tem espaco e acento.
    $linhaArgs = ($gfArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { "$_" }
    }) -join ' '

    $inicio = Get-Date
    $proc   = Start-Process -FilePath $exe -ArgumentList $linhaArgs -NoNewWindow -Wait -PassThru
    $saidaCodigo = $proc.ExitCode
    Write-VwfElapsed -Inicio $inicio -Rotulo 'Estabilizacao'

    # O exit code do Gyroflow nao e confiavel (app de GUI), entao ele so vira
    # aviso: quem decide e a existencia e a sanidade do arquivo de saida.
    if ($saidaCodigo -ne 0) {
        Write-Warning "Gyroflow retornou codigo $saidaCodigo; conferindo as saidas assim mesmo."
    }

    # A saida do Gyroflow e longa demais para se achar um aviso nela, entao o
    # resultado vai em bloco no fim.
    Write-Host ''
    Write-Host '--- Resultado da estabilizacao ---' -ForegroundColor Cyan

    if ($DeleteSource) {
        Remove-VwfStabilizedSources -Project $Project
    } else {
        foreach ($p in $pendentes) {
            $saida = Get-VwfStabilizedOutput -WorkDir $work -BaseName $p.BaseName
            if ($saida) {
                Write-Host ("  {0} -> {1} ({2:n2} GB)" -f $p.Name, $saida.Name, ($saida.Length / 1GB)) -ForegroundColor Green
            } else {
                Write-Warning "$($p.Name): saida nao encontrada em $work."
            }
        }
    }

    Get-ChildItem -LiteralPath $work -File -Filter "*$sufixo.*"
}

function Get-VwfStabilizedOutput {
    <#
    .SYNOPSIS
        Devolve o arquivo estabilizado correspondente a um nome base, desde que
        exista, nao esteja vazio e nao esteja sendo escrito. Senao, $null.
    .DESCRIPTION
        Busca por padrao em vez de nome exato, para cobrir diferenca de extensao
        ou de maiusculas que o Gyroflow possa aplicar na saida.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$BaseName
    )

    $cfg = Get-VwfConfig
    $f = Get-ChildItem -LiteralPath $WorkDir -File -Filter "$BaseName$($cfg.StabSuffix).*" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $f) { return $null }
    if ($f.Length -eq 0) { Write-Warning "$($f.Name) esta vazio."; return $null }
    if (-not (Test-VwfFileReady $f.FullName)) { Write-Warning "$($f.Name) ainda esta sendo escrito."; return $null }
    $f
}

function Remove-VwfStabilizedSources {
    <#
    .SYNOPSIS
        Remove de <projeto>\work os arquivos unidos que ja tem um estabilizado
        valido correspondente. Independe de ter renderizado nesta sessao.
    .EXAMPLE
        Remove-VwfStabilizedSources -Project $proj -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Project)

    $cfg    = Get-VwfConfig
    $work   = Get-VwfWorkDir -Project $Project
    $sufixo = $cfg.StabSuffix

    $origens = Get-ChildItem -LiteralPath $work -File -Filter '*.MP4' |
               Where-Object { $_.BaseName -notlike "*$sufixo" } | Sort-Object Name

    if (-not $origens) { Write-Host 'Nenhum arquivo unido em work.' -ForegroundColor DarkGray; return }

    $removidos = 0
    foreach ($o in $origens) {
        $saida = Get-VwfStabilizedOutput -WorkDir $work -BaseName $o.BaseName
        if (-not $saida) {
            Write-Warning "$($o.Name): sem estabilizado valido; preservado."
            continue
        }

        Write-Host ("  {0} -> {1} ({2:n2} GB)" -f $o.Name, $saida.Name, ($saida.Length / 1GB)) -ForegroundColor Green

        if ($PSCmdlet.ShouldProcess($o.Name, 'Remover arquivo unido')) {
            try {
                Remove-Item -LiteralPath $o.FullName -Force -ErrorAction Stop
                Write-Host '    original removido' -ForegroundColor DarkGray
                $removidos++
            } catch {
                Write-Warning "$($o.Name): nao foi possivel remover ($($_.Exception.Message))."
            }
        }
    }

    if ($removidos) { Write-Host "$removidos original(is) removido(s)." -ForegroundColor DarkGray }
}

#endregion

#region juncao final e compactacao ------------------------------------------

function Get-VwfTimeline {
    <#
    .SYNOPSIS
        Lista os videos estabilizados em ordem cronologica de gravacao.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)

    $cfg  = Get-VwfConfig
    $work = Get-VwfWorkDir -Project $Project

    Get-ChildItem -LiteralPath $work -File -Filter "*$($cfg.StabSuffix).*" |
        ForEach-Object {
            [pscustomobject]@{
                Arquivo  = $_.Name
                Inicio   = Get-VwfCreationTime $_.FullName
                Duracao  = [timespan]::FromSeconds((Get-VwfDuration $_.FullName))
                FullName = $_.FullName
            }
        } | Sort-Object Inicio
}

function Join-VwfStabilized {
    <#
    .SYNOPSIS
        Une os videos estabilizados em um unico arquivo, em ordem cronologica.
    .PARAMETER Order
        Ordem manual dos arquivos (nomes), quando o horario das cameras nao for confiavel.
    .PARAMETER Name
        Nome do arquivo final, sem extensao. Por padrao, o nome da pasta do projeto.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string[]]$Order,
        [string]$Name,
        [switch]$DeleteSource,
        [switch]$IgnoreSpace,
        [switch]$NoHighlights,
        [switch]$Force
    )

    $cfg  = Get-VwfConfig
    $work = Get-VwfWorkDir -Project $Project
    if (-not $Name) { $Name = Split-Path $Project -Leaf }

    if ($Order) {
        $lista = $Order | ForEach-Object {
            $f = Join-Path $work $_
            if (-not (Test-Path -LiteralPath $f)) { throw "Arquivo nao encontrado: $_" }
            Get-Item -LiteralPath $f
        }
    } else {
        $lista = (Get-VwfTimeline -Project $Project) | ForEach-Object { Get-Item -LiteralPath $_.FullName }
    }

    if (-not $lista) { Write-Warning 'Nenhum video estabilizado encontrado.'; return }

    # O master herda a extensao das entradas (.mov quando o preset preserva as
    # outras trilhas). Misturar containers no mp4_merge nao e seguro.
    $exts = @($lista | ForEach-Object { $_.Extension.ToLower() } | Sort-Object -Unique)
    if ($exts.Count -gt 1) {
        throw "Os estabilizados tem extensoes diferentes ($($exts -join ', ')). Refaca a estabilizacao com um preset so."
    }
    $destino = Join-Path $Project "$Name$($exts[0])"
    if ((Test-Path -LiteralPath $destino) -and -not $Force) { throw "Ja existe: $destino (use -Force)" }

    Write-Host 'Ordem da juncao:' -ForegroundColor Cyan
    $i = 1
    foreach ($f in $lista) {
        $ini = Get-VwfCreationTime $f.FullName
        Write-Host ("  {0,2}. {1}  (gravado {2:yyyy-MM-dd HH:mm} UTC)" -f $i++, $f.Name, $ini) -ForegroundColor Gray
    }

    Assert-VwfSpace -Path $Project -Required (($lista | Measure-Object Length -Sum).Sum) `
        -IgnoreSpace:$IgnoreSpace -Operacao 'Juncao final' | Out-Null

    if (-not $PSCmdlet.ShouldProcess($destino, "Unir $($lista.Count) video(s)")) { return }

    $inicio = Get-Date
    & $cfg.Tools.Mp4Merge $lista.FullName --out $destino
    if ($LASTEXITCODE -ne 0) { Write-Error 'mp4_merge falhou na juncao final.'; return }
    Write-VwfElapsed -Inicio $inicio -Rotulo 'Juncao final'

    $check = Test-VwfMerge -Result $destino -Parts $lista
    $ok    = $check.Ok
    Write-VwfMergeCheck -Check $check

    # Junta os sidecars de HiLight na mesma ordem, deslocando cada clipe pela
    # duracao acumulada dos anteriores, e grava como capitulos no master.
    if ($ok -and -not $NoHighlights) {
        $todas = New-Object System.Collections.Generic.List[int64]
        $desl  = [double]0

        foreach ($f in $lista) {
            $padrao = ([regex]::Escape($cfg.StabSuffix)) + '$'
            $base   = $f.BaseName -replace $padrao, ''
            $side = Join-Path $work "$base.hilights.json"
            if (Test-Path -LiteralPath $side) {
                $d = Get-Content -LiteralPath $side -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($ms in @($d.hilights_ms)) { $todas.Add([int64]($ms + ($desl * 1000))) }
            }
            $dur = Get-VwfDuration $f.FullName
            if ($dur) { $desl += $dur }
        }

        if ($todas.Count) {
            $ordenadas = @($todas | Sort-Object -Unique)
            $sidecarFinal = Join-Path $Project "$Name.hilights.json"
            [pscustomobject]@{
                source       = Split-Path $destino -Leaf
                extracted_at = (Get-Date).ToString('o')
                count        = $ordenadas.Count
                hilights_ms  = $ordenadas
                hilights_hms = @($ordenadas | ForEach-Object {
                    [timespan]::FromMilliseconds($_).ToString('hh\:mm\:ss\.fff')
                })
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $sidecarFinal -Encoding UTF8

            Write-Host "$($ordenadas.Count) HiLight(s) consolidados em $Name.hilights.json" -ForegroundColor DarkGray
            Add-VwfChapters -Path $destino -Highlights $sidecarFinal | Out-Null
        }
    }

    if ($DeleteSource -and $ok) {
        if ($PSCmdlet.ShouldProcess("$($lista.Count) estabilizados em work", 'Remover intermediarios')) {
            $lista | Remove-Item -Force
        }
    }

    Get-Item -LiteralPath $destino
}

function Compress-VwfVideo {
    <#
    .SYNOPSIS
        Gera a copia compactada para arquivo morto.
    .PARAMETER ProfileName
        Nome de um perfil da secao Compression do config (R4, R4GPU, CRF28...).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Project')][string]$Project,
        [Parameter(ParameterSetName = 'Project')][string]$Name,
        [Parameter(Mandatory, ParameterSetName = 'File')][string]$Path,
        [Alias('Profile')][string]$ProfileName = 'R4',
        [switch]$IgnoreSpace,
        [switch]$Force
    )

    $cfg = Get-VwfConfig
    if (-not $cfg.Compression.ContainsKey($ProfileName)) {
        throw "Perfil '$ProfileName' nao existe. Disponiveis: $($cfg.Compression.Keys -join ', ')"
    }
    $perfil = $cfg.Compression[$ProfileName]

    if ($PSCmdlet.ParameterSetName -eq 'Project') {
        if (-not $Name) { $Name = Split-Path $Project -Leaf }
        $m = Get-VwfMaster -Project $Project -Name $Name
        if (-not $m) { throw "Master nao encontrado em $Project (procurei por '$Name.*')." }
        $Path = $m.FullName
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo nao encontrado: $Path" }

    $src     = Get-Item -LiteralPath $Path
    $destino = Join-Path $src.DirectoryName "$($src.BaseName)$($perfil.Suffix).mp4"

    if ((Test-Path -LiteralPath $destino) -and -not $Force) { throw "Ja existe: $destino (use -Force)" }

    # Estimativa pela duracao x bitrate do perfil, quando ha bitrate definido;
    # caso contrario (CRF), usa uma fracao do original.
    $idx = [array]::IndexOf($perfil.Args, '-b:v')
    $estimado = if ($idx -ge 0) {
        $mbps = [double](($perfil.Args[$idx + 1]) -replace '[^\d.]', '')
        $dur  = Get-VwfDuration $src.FullName
        if ($dur) { ($mbps * 1MB / 8) * $dur * 1.15 } else { $src.Length * 0.35 }
    } else {
        $src.Length * 0.35
    }
    Assert-VwfSpace -Path $src.DirectoryName -Required $estimado -IgnoreSpace:$IgnoreSpace `
        -Operacao "Compactar com perfil $ProfileName" | Out-Null

    if (-not $PSCmdlet.ShouldProcess($destino, "Compactar com perfil $ProfileName")) { return }

    $ffArgs = @('-hide_banner', '-y', '-i', $src.FullName) + $perfil.Args + @($destino)
    $inicio = Get-Date
    & $cfg.Tools.FFmpeg @ffArgs
    if ($LASTEXITCODE -ne 0) { Write-Error 'ffmpeg falhou na compactacao.'; return }
    Write-VwfElapsed -Inicio $inicio -Rotulo "Compactacao $ProfileName"

    $out = Get-Item -LiteralPath $destino
    Write-Host ("{0:n2} GB -> {1:n2} GB ({2:n0}% do original)" -f
        ($src.Length / 1GB), ($out.Length / 1GB), (100 * $out.Length / $src.Length)) -ForegroundColor Green
    $out
}

function Remove-VwfMaster {
    <#
    .SYNOPSIS
        Apaga o arquivo grande (master) depois que ele ja subiu para o YouTube.
        Exige confirmacao explicita.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Project,
        [string]$Name,
        [switch]$RemoveWork
    )

    $cfg = Get-VwfConfig
    if (-not $Name) { $Name = Split-Path $Project -Leaf }
    $m = Get-VwfMaster -Project $Project -Name $Name

    if (-not $m) { Write-Warning "Master nao encontrado em $Project (procurei por '$Name.*')."; return }
    $master = $m.FullName

    $compactados = Get-ChildItem -LiteralPath $Project -File -Filter "$Name*_*.*" |
        Where-Object { $_.FullName -ne $master }

    if (-not $compactados) {
        Write-Warning 'Nenhuma copia compactada encontrada na pasta. Abortando por seguranca.'
        return
    }

    Write-Host 'Copia(s) compactada(s) encontrada(s):' -ForegroundColor Cyan
    $compactados | ForEach-Object { Write-Host ("  {0} ({1:n2} GB)" -f $_.Name, ($_.Length / 1GB)) -ForegroundColor Gray }
    Write-Host 'Confirme que o video ja esta no YouTube antes de prosseguir.' -ForegroundColor Yellow

    if ($PSCmdlet.ShouldProcess($master, 'Remover master')) {
        Remove-Item -LiteralPath $master -Force
    }
    if ($RemoveWork) {
        $work = Join-Path $Project $cfg.WorkDir
        if ((Test-Path -LiteralPath $work) -and $PSCmdlet.ShouldProcess($work, 'Remover pasta work')) {
            Remove-Item -LiteralPath $work -Recurse -Force
        }
    }
}

#endregion

#region status e utilitarios ------------------------------------------------

function Get-VwfStatus {
    <#
    .SYNOPSIS
        Mostra em que pe esta cada video do projeto.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Project)

    $cfg    = Get-VwfConfig
    $work   = Join-Path $Project $cfg.WorkDir
    $nome   = Split-Path $Project -Leaf
    $sufixo = $cfg.StabSuffix

    if (Test-Path -LiteralPath $work) {
        $unidos = Get-ChildItem -LiteralPath $work -File -Filter '*.MP4' |
                  Where-Object BaseName -notlike "*$sufixo"
        $estab  = Get-ChildItem -LiteralPath $work -File -Filter "*$sufixo.*"
    } else { $unidos = @(); $estab = @() }

    $livre = Get-VwfFreeSpace -Path $Project

    [pscustomobject]@{
        Projeto      = $nome
        Unidos       = $unidos.Count
        Estabilizados = $estab.Count
        Master       = [bool](Get-VwfMaster -Project $Project -Name $nome)
        Compactados  = (Get-ChildItem -LiteralPath $Project -File -Filter "$nome*_*.*" -ErrorAction SilentlyContinue).Count
        TamanhoWorkGB = if ($unidos -or $estab) { [math]::Round(((@($unidos) + @($estab)) | Measure-Object Length -Sum).Sum / 1GB, 2) } else { 0 }
        LivreGB      = if ($null -ne $livre) { [math]::Round($livre / 1GB, 2) } else { $null }
    }
}

function Write-VwfElapsed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime]$Inicio,
        [string]$Rotulo = 'Tempo total'
    )
    $t = (Get-Date) - $Inicio
    Write-Host ("{0}: {1} h, {2} min e {3} seg" -f $Rotulo, [int]$t.TotalHours, $t.Minutes, $t.Seconds) -ForegroundColor DarkCyan
}

#endregion

Export-ModuleMember -Function @(
    'Import-VwfConfig', 'Get-VwfConfig', 'Test-VwfTools',
    'Select-VwfProject', 'Get-VwfWorkDir', 'Get-VwfMaster',
    'Get-VwfCardInfo', 'Get-VwfCardClips', 'Clear-VwfCardJunk', 'Import-VwfCard',
    'Get-VwfHighlights', 'Export-VwfHighlights', 'Add-VwfChapters',
    'Invoke-VwfStabilize', 'Get-VwfStabilizedOutput', 'Remove-VwfStabilizedSources',
    'Show-VwfPresetPaths', 'New-VwfCleanPreset',
    'Get-VwfTimeline', 'Join-VwfStabilized',
    'Compress-VwfVideo', 'Remove-VwfMaster',
    'Get-VwfStatus', 'Get-VwfDuration', 'Get-VwfCreationTime', 'Get-VwfFrameRate',
    'Get-VwfFreeSpace', 'Test-VwfSpace', 'Assert-VwfSpace',
    'Test-VwfMerge', 'Write-VwfMergeCheck', 'Test-VwfFileReady', 'Write-VwfElapsed'
)
