@{
    # Caminhos dos executaveis. Se estiverem no PATH, basta o nome.
    Tools = @{
        Mp4Merge = 'mp4_merge-windows64'
        Gyroflow = 'Gyroflow'
        FFmpeg   = 'ffmpeg'
        FFprobe  = 'ffprobe'
    }

    # Caminhos relativos sao resolvidos a partir da pasta deste arquivo,
    # entao o preset pode ficar versionado junto com o modulo.
    Paths = @{
        DefaultSource = 'F:\DCIM\100GOPRO'
        ProjectsRoot  = 'D:\Pictures\Câmeras\2026'
        Preset        = 'presets/session5_superview_1080p_60fps.gyroflow'
    }

    # Rotulo do volume do cartao -> tag curta da camera.
    # O rotulo identifica a camera e evita colisao de nomes no destino.
    Cameras = @{
        'GPS5A' = 'S5A'
        'GPS5B' = 'S5B'
        'GPS5C' = 'S5C'
        'GPS5D' = 'S5D'
        'GPS5E' = 'S5E'
        'X4'    = 'X4'
    }

    # Usada quando o rotulo do cartao nao esta no mapa acima.
    DefaultCameraTag = 'CAM'

    # Sufixo que o Gyroflow acrescenta na saida (parametro -t).
    StabSuffix = '_stabilized'

    # Tolerancias da verificacao pos-merge.
    # Duracao: folga de DurationSec + DurationPart por arquivo de entrada.
    # SizePercent: desvio aceito entre o tamanho do resultado e a soma das partes.
    Tolerance = @{
        DurationSec   = 1.0
        DurationPart  = 0.2
        SizePercent   = 0.5
    }

    # Taxa de quadros esperada das cameras. O preset fixa o rolling shutter em
    # funcao do fps, entao arquivo em outra taxa sai com correcao errada: o
    # modulo separa esses e avisa. 0 desliga a conferencia.
    ExpectedFps = 59.94

    # Folga exigida, em %, sobre o espaco estimado para cada etapa.
    SpaceMarginPercent = 10

    # Quanto a saida do Gyroflow costuma ocupar em relacao a entrada.
    # Medido no preset atual: ~1.002 (saida 0,2% maior que a entrada).
    # Ajuste se mudar o bitrate do preset.
    StabSizeFactor = 1.05

    # Perfis de compactacao para o arquivo morto.
    Compression = @{
        R4 = @{
            Suffix = '_R4_265_acopy'
            Args   = @('-vcodec', 'libx265', '-b:v', '2M', '-maxrate', '3M', '-bufsize', '3M', '-c:a', 'copy')
        }
        R4GPU = @{
            Suffix = '_R4_nvenc_acopy'
            Args   = @('-vcodec', 'hevc_nvenc', '-preset', 'p6', '-b:v', '2M', '-maxrate', '3M', '-bufsize', '3M', '-c:a', 'copy')
        }
        CRF28 = @{
            Suffix = '_crf28_265_acopy'
            Args   = @('-vcodec', 'libx265', '-crf', '28', '-preset', 'slow', '-c:a', 'copy')
        }
    }

    # Subpasta de trabalho dentro do projeto (intermediarios).
    WorkDir = 'work'
}
