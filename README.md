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

Vídeos de uma parte só são tratados: o módulo copia direto para `work` com o
nome ajustado, sem chamar o `mp4_merge`. A verificação pós-cópia é a mesma.

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
ficam no config. Se o seu preset do Gyroflow gerar saída bem maior que a
entrada, suba o `StabSizeFactor`.

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
