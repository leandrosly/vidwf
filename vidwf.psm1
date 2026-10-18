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

    $script:VwfConfig     = Import-PowerShellDataFile -LiteralPath $Path
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
            Conferiu = $ok
        }
    }
}

#endregion

#region estabilizacao -------------------------------------------------------

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
        [switch]$Force
    )

    $cfg  = Get-VwfConfig
    $work = Get-VwfWorkDir -Project $Project
    if (-not $Preset) { $Preset = $cfg.Paths.Preset }

    if (-not (Test-Path -LiteralPath $Preset)) { throw "Preset nao encontrado: $Preset" }

    $sufixo    = $cfg.StabSuffix
    $pendentes = Get-ChildItem -LiteralPath $work -File -Filter '*.MP4' |
        Where-Object { $_.BaseName -notlike "*$sufixo" } |
        Where-Object {
            $Force -or -not (Test-Path -LiteralPath (Join-Path $work "$($_.BaseName)$sufixo.mp4"))
        } |
        Where-Object {
            # Evita pegar um arquivo que outra aba ainda esta escrevendo.
            if (Test-VwfFileReady $_.FullName) { $true }
            else { Write-Warning "$($_.Name) esta em uso por outro processo; sera ignorado nesta rodada."; $false }
        } | Sort-Object Name

    if (-not $pendentes) { Write-Host 'Nada pendente para estabilizar.' -ForegroundColor DarkGray; return }

    Write-Host "Estabilizando $($pendentes.Count) video(s):" -ForegroundColor Cyan
    $pendentes.Name | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }

    if (-not $PSCmdlet.ShouldProcess("$($pendentes.Count) video(s) em $work", 'Gyroflow')) { return }

    $gfArgs = @($pendentes.FullName) + @('--preset', $Preset, '-t', $sufixo, '--stdout-progress')
    if ($Parallel -gt 1) { $gfArgs += @('-j', "$Parallel") }
    if ($Force)          { $gfArgs += '-f' }
    if ($OutParams)      { $gfArgs += @('-p', ($OutParams -join ' ')) }

    $inicio = Get-Date
    & $cfg.Tools.Gyroflow @gfArgs
    $saidaCodigo = $LASTEXITCODE
    Write-VwfElapsed -Inicio $inicio -Rotulo 'Estabilizacao'

    if ($saidaCodigo -ne 0) { Write-Error "Gyroflow retornou codigo $saidaCodigo."; return }

    foreach ($p in $pendentes) {
        $saida = Join-Path $work "$($p.BaseName)$sufixo.mp4"
        if (-not (Test-Path -LiteralPath $saida)) {
            Write-Warning "Saida nao encontrada para $($p.Name)."
            continue
        }
        if ($DeleteSource -and $PSCmdlet.ShouldProcess($p.Name, 'Remover arquivo unido')) {
            Remove-Item -LiteralPath $p.FullName -Force
        }
    }

    Get-ChildItem -LiteralPath $work -File -Filter "*$sufixo.mp4"
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

    Get-ChildItem -LiteralPath $work -File -Filter "*$($cfg.StabSuffix).mp4" |
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
        [switch]$Force
    )

    $cfg  = Get-VwfConfig
    $work = Get-VwfWorkDir -Project $Project
    if (-not $Name) { $Name = Split-Path $Project -Leaf }
    $destino = Join-Path $Project "$Name.mp4"

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
    if ((Test-Path -LiteralPath $destino) -and -not $Force) { throw "Ja existe: $destino (use -Force)" }

    Write-Host 'Ordem da juncao:' -ForegroundColor Cyan
    $i = 1
    foreach ($f in $lista) {
        $ini = Get-VwfCreationTime $f.FullName
        Write-Host ("  {0,2}. {1}  (gravado {2:yyyy-MM-dd HH:mm} UTC)" -f $i++, $f.Name, $ini) -ForegroundColor Gray
    }

    if (-not $PSCmdlet.ShouldProcess($destino, "Unir $($lista.Count) video(s)")) { return }

    $inicio = Get-Date
    & $cfg.Tools.Mp4Merge $lista.FullName --out $destino
    if ($LASTEXITCODE -ne 0) { Write-Error 'mp4_merge falhou na juncao final.'; return }
    Write-VwfElapsed -Inicio $inicio -Rotulo 'Juncao final'

    $check = Test-VwfMerge -Result $destino -Parts $lista
    $ok    = $check.Ok
    Write-VwfMergeCheck -Check $check

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
        [switch]$Force
    )

    $cfg = Get-VwfConfig
    if (-not $cfg.Compression.ContainsKey($ProfileName)) {
        throw "Perfil '$ProfileName' nao existe. Disponiveis: $($cfg.Compression.Keys -join ', ')"
    }
    $perfil = $cfg.Compression[$ProfileName]

    if ($PSCmdlet.ParameterSetName -eq 'Project') {
        if (-not $Name) { $Name = Split-Path $Project -Leaf }
        $Path = Join-Path $Project "$Name.mp4"
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Arquivo nao encontrado: $Path" }

    $src     = Get-Item -LiteralPath $Path
    $destino = Join-Path $src.DirectoryName "$($src.BaseName)$($perfil.Suffix).mp4"

    if ((Test-Path -LiteralPath $destino) -and -not $Force) { throw "Ja existe: $destino (use -Force)" }
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
    $master = Join-Path $Project "$Name.mp4"

    if (-not (Test-Path -LiteralPath $master)) { Write-Warning "Master nao encontrado: $master"; return }

    $compactados = Get-ChildItem -LiteralPath $Project -File -Filter "$Name*_*.mp4" |
        Where-Object { $_.Name -ne "$Name.mp4" }

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
        $estab  = Get-ChildItem -LiteralPath $work -File -Filter "*$sufixo.mp4"
    } else { $unidos = @(); $estab = @() }

    [pscustomobject]@{
        Projeto      = $nome
        Unidos       = $unidos.Count
        Estabilizados = $estab.Count
        Master       = Test-Path -LiteralPath (Join-Path $Project "$nome.mp4")
        Compactados  = (Get-ChildItem -LiteralPath $Project -File -Filter "$nome*_*.mp4" -ErrorAction SilentlyContinue).Count
        TamanhoWorkGB = if ($unidos -or $estab) { [math]::Round(((@($unidos) + @($estab)) | Measure-Object Length -Sum).Sum / 1GB, 2) } else { 0 }
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
    'Select-VwfProject', 'Get-VwfWorkDir',
    'Get-VwfCardInfo', 'Get-VwfCardClips', 'Clear-VwfCardJunk', 'Import-VwfCard',
    'Invoke-VwfStabilize',
    'Get-VwfTimeline', 'Join-VwfStabilized',
    'Compress-VwfVideo', 'Remove-VwfMaster',
    'Get-VwfStatus', 'Get-VwfDuration', 'Get-VwfCreationTime',
    'Test-VwfMerge', 'Write-VwfMergeCheck', 'Test-VwfFileReady', 'Write-VwfElapsed'
)
