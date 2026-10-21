# vidwf

Módulo PowerShell para o workflow de vídeo das câmeras de ação (GoPro Session 5
e, futuramente, Insta360 X4): unir capítulos → estabilizar no Gyroflow → juntar
tudo em um master → compactar para arquivo morto.

Requer PowerShell 7+.

## Instalação

1. Coloque `vidwf.psm1` e `vidwf.config.psd1` na mesma pasta.
2. Ajuste `vidwf.config.psd1` (caminhos das ferramentas, preset, pastas).
3. Importe:

```powershell
Import-Module 'D:\Documents\Projetos\Video Workflow\vidwf.psm1' -Force
Test-VwfTools   # confere se mp4_merge, Gyroflow, ffmpeg e ffprobe estão acessíveis
```

Para não digitar o import toda vez, acrescente a linha ao seu `$PROFILE`.

### Rótulo dos cartões (importante)

O módulo identifica a câmera pelo **rótulo do volume** do cartão. É isso que
evita que `GOPR0055` de duas Session 5 diferentes se sobrescrevam no destino.
Renomeie cada cartão uma única vez (no Explorer ou via `label F: GPS5-01`) e
registre o mapa em `Cameras` no config. Cartão fora do mapa gera aviso e usa o
próprio rótulo como tag.

## Uso típico

```powershell
# 1. Pasta do passeio (abre o seletor na raiz dos projetos)
$proj = Select-VwfProject
# ou: $proj = Select-VwfProject -New '2026.10.16 - Passeio noturno de mono com o Gabriel'

# 2. Para cada cartão: limpa LRV/THM, une os capítulos, apaga os originais
Import-VwfCard -Project $proj -CleanJunk -DeleteSource

# (troca o cartão e repete a linha acima)

# 3. Estabiliza tudo que estiver pendente
Invoke-VwfStabilize -Project $proj -DeleteSource

# 4. Confere a ordem e junta no master
Get-VwfTimeline -Project $proj
Join-VwfStabilized -Project $proj -DeleteSource

# 5. >>> subir o master para o YouTube <<<

# 6. Compacta e, só depois de confirmar o upload, apaga o master
Compress-VwfVideo -Project $proj -ProfileName R4
Remove-VwfMaster -Project $proj -RemoveWork
```

Todo comando destrutivo aceita `-WhatIf` para simular.

`Remove-VwfMaster` exige que exista uma cópia compactada na pasta e, se o master
já tiver sido apagado numa tentativa anterior, segue em frente com o resto da
limpeza em vez de abortar. A remoção do `work` é um comando próprio, que pode
ser chamado sozinho e sai da pasta antes de removê-la (estar dentro dela pelo
prompt faz o Windows recusar a remoção):

```powershell
Remove-VwfWorkDir -Project $proj
```

Vídeos de uma parte só são tratados: o módulo copia direto para `work` com o
nome ajustado, sem chamar o `mp4_merge`. A verificação pós-cópia é a mesma.

O `-DeleteSource` do `Invoke-VwfStabilize` não depende de ter renderizado
naquela execução: se os `_stabilized` já existiam de uma rodada anterior, ele
limpa os unidos correspondentes mesmo assim. Para fazer só a limpeza:

```powershell
Remove-VwfStabilizedSources -Project $proj -WhatIf   # tire o -WhatIf para valer
```

### Onde fica o preset

Os presets ficam em `presets/`, versionados junto com o módulo. `Paths.Preset`
aceita caminho relativo, resolvido a partir da pasta do `vidwf.config.psd1`:

```powershell
Preset = 'presets/session5_superview_1080p_60fps.gyroflow'
```

O nome segue `<câmera>_<lente>_<resolução>_<fps>`, porque cada um desses campos
muda o preset: a lente vem do perfil de calibração, que é específico do modelo
da câmera, e o fps determina o rolling shutter. Vizinhos previstos:
`session5_superview_1080p_30fps.gyroflow`, `session5_wide_1080p_60fps.gyroflow`.

Para usar outro preset em uma execução específica, sem mexer no config:

```powershell
Invoke-VwfStabilize -Project $proj -Preset 'D:\...\outro.gyroflow'
```

## HiLight tags

As HiLight tags (botão/voz na câmera) ficam em `/moov/udta/HMMT` — uma caixa de
metadados, **não** uma trilha. Por isso:

- a estabilização no Gyroflow não as leva junto;
- o `mp4_merge` só herda os metadados do **primeiro** capítulo, então as tags de
  `GP01`, `GP02`… se perderiam na união;
- `preserve_other_tracks` no preset não resolve, porque preserva trilhas.

O módulo cuida disso sozinho. No `Import-VwfCard`, enquanto os arquivos do
cartão ainda existem, ele lê as tags de **cada parte**, desloca pela duração
acumulada das anteriores e grava um sidecar ao lado do unido:

```
work\S5C_0067.hilights.json
```

No `Join-VwfStabilized`, os sidecars são consolidados na mesma ordem da junção
(cada clipe deslocado pela sua posição no vídeo final), gravados como
`<projeto>.hilights.json` e escritos **de volta no master como capítulos**, que
é o que aparece na linha do tempo do player.

Os capítulos são gravados com `-codec copy` (sem reencodar) e o original só é
substituído depois de conferida a duração. Não são a box `HMMT` original — o
ffmpeg não a escreve — mas cumprem a mesma função e são lidos por mais
programas. Um capítulo "Inicio" em 0 é sempre incluído, porque o muxer do ffmpeg
força o primeiro capítulo para o começo do arquivo; sem ele, a primeira HiLight
seria puxada para 0.

Para gravar capítulos num arquivo avulso:

```powershell
Add-VwfChapters -Path 'D:\...\video.mp4'                  # usa video.hilights.json
Add-VwfChapters -Path '...' -Highlights '...' -OutFile '...'   # sem substituir
```

Para só ler as tags de um arquivo GoPro:

```powershell
Get-VwfHighlights -Path 'F:\DCIM\100GOPRO\GOPR0067.MP4'
```

`-NoHighlights` desliga a extração no import e a gravação na junção.

### Extensão da saída e `preserve_other_tracks`

A saída normal é `.mp4`. Com `preserve_other_tracks: true` no preset, o Gyroflow
grava `.mov`: a trilha GPMF é um stream de dados (`gpmd`/`bin_data`), que o
muxer MP4 do ffmpeg recusa e o MOV aceita.

**O preset vem com essa opção desligada, de propósito.** Na Session 5 o GPMF só
traz giroscópio, acelerômetro e temperatura (ela não tem GPS), e o giro só
serviria para re-estabilizar, o que não se faz a partir de um arquivo já
estabilizado. Além disso, ela **não** preserva as HiLight tags: elas ficam em
`/moov/udta/HMMT`, uma caixa de metadados, não uma trilha — por isso o
marcador some do player mesmo com a opção ligada.

Mesmo assim, o módulo não assume extensão em lugar nenhum: procura por padrão
(`*_stabilized.*`) e o master herda a extensão dos estabilizados. Se houver
`.mov` e `.mp4` misturados no `work`, `Join-VwfStabilized` recusa em vez de
juntar contêineres diferentes.

### Por que `Start-Process -Wait`

O Gyroflow é um aplicativo de GUI. Chamado direto (`& Gyroflow ...`), o
PowerShell devolve o prompt imediatamente e o render continua solto em segundo
plano — a conferência das saídas rodaria antes de existirem, e nada seria
removido. O sintoma é `Estabilizacao: 0 h, 0 min e 0 seg` seguido de avisos de
"sem estabilizado valido", com os logs do Gyroflow aparecendo depois do prompt.

Por isso o módulo chama o Gyroflow com `Start-Process -Wait`, citando os
argumentos manualmente (os caminhos têm espaços e acentos).

### Saída do Gyroflow no terminal

Por padrão o módulo não passa `--stdout-progress`: ele duplica o progresso em
milhares de linhas e enterra qualquer aviso. O resultado de cada vídeo sai em
um bloco no fim, depois do ruído do render. Para o modo verborrágico,
`Invoke-VwfStabilize -StdoutProgress`.

### Taxa de quadros e rolling shutter

O preset fixa o tempo de rolling shutter, e esse valor depende do fps: o
controle na GUI vai de 0 até a duração do quadro, então 60p permite no máximo
16,68 ms e 30p, 33,37 ms. Um preset de 60p aplicado a footage de 30p
subcorrige o rolling shutter pela metade.

Por isso o preset tem a taxa no nome, e o módulo confere: antes de estabilizar,
lê o fps de cada arquivo e separa os que não batem com `ExpectedFps` do config.

```
AVISO: S5B_0071.MP4: 29,97 fps, esperado 59,94. Fora desta rodada - use
-Preset com um preset dessa taxa, ou -IgnoreFps.
```

Para processá-los, rode de novo com o preset certo:

```powershell
Invoke-VwfStabilize -Project $proj -Preset '...\preset_session5_fullhd_30fps.gyroflow' -ExpectedFps 29.97
```

`ExpectedFps = 0` no config desliga a conferência; `-IgnoreFps` ignora só naquela execução.

### Preset e pasta de saída

Um preset salvo pela GUI com todas as opções marcadas carrega junto a **pasta de
saída em uso naquele momento**. Depois disso, todo render feito com ele cai
naquela pasta — não importa onde está a entrada nem em que diretório o prompt
está, então `cd` não resolve. Isso reaparece toda vez que você regrava o preset.

O módulo contorna sozinho: antes de chamar o Gyroflow, ele gera uma cópia
temporária do preset sem as chaves de caminho e usa essa cópia. O preset
original não é alterado. Quando remove algo, avisa:

```
Preset: removidos 1 caminho(s) de saida para esta execucao:
  output.output_folder = D:/Pictures/Câmeras/2026/2026.10.20 - Até o ginásio de mono
```

Para ver o que o preset carrega, sem mexer em nada:

```powershell
Show-VwfPresetPaths
```

Para desligar a limpeza e usar o preset como está, `Invoke-VwfStabilize -RawPreset`.

### Refazer a estabilização com outro preset

Se o preset mudou, as saídas antigas continuam no `work` e nada no nome delas
indica com qual preset foram feitas. Apague antes de rodar de novo, em vez de
usar `-Force`, para não misturar versões:

```powershell
Get-ChildItem $work -Filter '*_stabilized.*' | Remove-Item -Verbose
Invoke-VwfStabilize -Project $proj -DeleteSource
```

Um unido só é removido se houver um estabilizado correspondente que exista, não
esteja vazio e não esteja sendo escrito por outro processo.

## Estrutura de pastas

```
<projeto>\
  work\                      intermediários
    S5A_0055.MP4             capítulos unidos (prefixo = câmera)
    S5A_0055_stabilized.mp4  saída do Gyroflow
  <nome do projeto>.mp4      master (vai para o YouTube)
  <nome do projeto>_R4_265_acopy.mp4   cópia compactada
```

## Ordem da junção final

`Join-VwfStabilized` ordena pelo **horário de gravação** (metadado do arquivo),
não pela numeração — é o que resolve o caso de alternar entre câmeras durante o
passeio. Isso só funciona se os relógios das câmeras estiverem acertados.
Se a ordem sair errada, passe manualmente:

```powershell
Join-VwfStabilized -Project $proj -Order 'S5A_0060_stabilized.mp4','S5B_0057_stabilized.mp4'
```

## Trabalhando em paralelo

Cada comando é um processo independente, então continua valendo abrir várias
abas: unir o cartão 2 em uma enquanto a outra estabiliza o cartão 1.
`Invoke-VwfStabilize` ignora arquivos que ainda estão abertos por outro
processo, então não pega um merge pela metade. Para render paralelo dentro de
uma chamada só, use `-Parallel 2` (disputa GPU — meça antes de subir).

## Espaço em disco

Cada etapa que escreve arquivo grande confere o espaço livre do destino antes
de começar e aborta com mensagem clara se não couber:

```
Espaco insuficiente. Importar 4 video(s) do cartao S5A: precisa de ~31,2 GB
(com folga), ha 18,4 GB livres em D:\. Faltam ~12,8 GB.
```

A estimativa é feita assim:

| Etapa | Base da estimativa |
|---|---|
| `Import-VwfCard` | soma das partes que serão escritas (pula o que já existe) |
| `Invoke-VwfStabilize` | soma das entradas × `StabSizeFactor` |
| `Join-VwfStabilized` | soma dos estabilizados |
| `Compress-VwfVideo` | duração × bitrate do perfil (ou 35% do original, em perfis CRF) |

Sobre tudo isso incide a folga de `SpaceMarginPercent` (10% por padrão). Os dois
ficam no config. O `StabSizeFactor` está em 1.05: medido no preset atual, a
saída do Gyroflow fica ~0,2% maior que a entrada. Se mudar o bitrate do preset,
compare um `_stabilized` com a entrada e ajuste.

Para forçar mesmo assim, todos esses comandos aceitam `-IgnoreSpace` (avisa e
segue). E `Get-VwfStatus` mostra o espaço livre junto com o resto:

```powershell
Get-VwfStatus -Project $proj
```

## Verificação

Depois de cada junção o módulo compara **duração e tamanho** do resultado com a
soma das partes, e só apaga os originais se os dois baterem. Se divergir,
preserva tudo e avisa qual dos dois falhou.

A duração sozinha não pegaria um merge truncado: se o `stbl` foi escrito inteiro
mas o `mdat` ficou pela metade, o arquivo "dura" o esperado e falha no meio. O
tamanho pega esse caso. A comparação de tamanho é percentual, não exata, porque
o container do resultado tem overhead próprio (`stbl` refeito, `stco` virando
`co64`). As tolerâncias ficam em `Tolerance` no config — comece com os padrões
(1 s + 0,2 s por parte; 0,5% no tamanho) e aperte se achar folgado.

Para inspecionar um merge antigo sem refazer nada:

```powershell
Test-VwfMerge -Result 'work\S5A_0055.MP4' -Parts (Get-ChildItem 'F:\DCIM\100GOPRO\G*0055.MP4')
```

## Pendências / ideias

- Insta360 X4 via Media SDK (stitch por CLI) como mais um tipo de importação.
- Upload para o YouTube via API (exige projeto no Google Cloud + OAuth; projeto
  não auditado sobe vídeo como privado).
- Cortes curtos automáticos a partir das HiLight tags do GPMF.
- Interface gráfica (WPF) por cima dos mesmos cmdlets.
