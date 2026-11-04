MZPrisonConfig = {
  clockMode = 'online',
  tickSeconds = 30,

  -- STAGING MZ-RP-STAGING-2. O preset bolingbroke usa coordenadas candidatas e
  -- precisa ser confirmado no mapa/MLO real antes de producao.
  -- Deve espelhar mz_police/server/config.lua (ruleCode, name, legalVersion e duracao).
  -- Conversao usada: 1 mes = 60 segundos. Referencia:
  -- mz_docs/police/P13_PENAL_CODE_AND_PATROL.md.

  -- Intake nao teleporta: apenas valida proximidade/routing bucket no servidor.
  -- Com confinement habilitado, os pontos vivem dentro da facility.
  intakeEnabled = false,
  intakeMaximumDistance = 3.0,
  intakePoints = {},

  -- Preset de STAGING baseado em Bolingbroke. As coordenadas sao candidatas e
  -- precisam ser confirmadas no MLO/bucket real antes de producao.
  -- O servidor conserva a autoridade sobre bucket, posicao, cela e area.
  confinement = {
    enabled = true,
    correctionCooldownSeconds = 10,
    resumeGraceSeconds = 15
  },
  facilities = {
    bolingbroke = {
      enabled = true,
      orgCode = 'police',
      label = 'Bolingbroke',
      routingBucket = 0,
      intakePoints = {
        booking = {
          enabled = true,
          coords = { x = 1847.14, y = 2585.90, z = 45.68 },
          radius = 3.0,
          routingBucket = 0,
          drawDistance = 15.0,
          label = '[E] Recebimento prisional',
          marker = { enabled = true, type = 1 },
          blip = { enabled = true, sprite = 188, color = 1, scale = 0.8, label = 'Recebimento prisional' }
        }
      },
      cells = {
        cell_a = {
          enabled = true,
          coords = { x = 1680.10, y = 2513.00, z = 45.50 },
          heading = 0.0
        }
      },
      allowedAreas = {
        cell_block = {
          enabled = true,
          coords = { x = 1680.10, y = 2513.00, z = 45.50 },
          radius = 30.0
        },
        yard = {
          enabled = true,
          coords = { x = 1691.65, y = 2564.11, z = 45.56 },
          radius = 30.0
        }
      }
    }
  },

  -- Uniforme usa itens canonicos de vestuario do mz_inventory. Sem assets e
  -- metadados aprovados, permanece desligado e nao inventa aparencia.
  uniform = { enabled = false, garments = {} },

  -- Soltura: destino de staging habilitado em Bolingbroke. Confirme piso,
  -- colisao, heading e bucket no MLO real. Sem ponto valido, a soltura conclui
  -- sem teleporte; com mais de um ponto valido, nenhum e escolhido.
  releasePoints = {
    bolingbroke_exit = {
      enabled = true,
      orgCode = 'police',
      coords = { x = 1837.14, y = 2591.40, z = 45.01 },
      heading = 175.68,
      radius = 3.0,
      routingBucket = 0
    }
  },

  sentenceRulesEnabled = true,
  legalVersion = 'MZ-RP-STAGING-2',
  jurisdictions = { police = { enabled = true } },

  -- P7.4B -- agregacao de multiples acusacoes habilitada em staging para o
  -- catalogo MZ-RP-STAGING-2. 'sum' e a unica politica implementada; qualquer
  -- outro valor falha fechado. O teto de 7200s acompanha MZPoliceConfig.Arrest.
  multiCharge = {
    enabled = true,
    maximumCharges = 3,
    maximumSentenceSeconds = 7200,
    aggregation = 'sum'
  },

  sentenceRules = {
    HOMICIDIO_DOLOSO = {
      enabled = true,
      name = 'Homicídio doloso',
      durationSeconds = 7200
    },
    HOMICIDIO_CULPOSO = {
      enabled = true,
      name = 'Homicídio culposo',
      durationSeconds = 2400
    },
    LATROCINIO = {
      enabled = true,
      name = 'Latrocínio',
      durationSeconds = 7200
    },
    LESAO_CORPORAL_GRAVE = {
      enabled = true,
      name = 'Lesão corporal grave',
      durationSeconds = 2400
    },
    TENTATIVA_HOMICIDIO = {
      enabled = true,
      name = 'Tentativa de homicídio',
      durationSeconds = 4800
    },
    ROUBO = {
      enabled = true,
      name = 'Roubo',
      durationSeconds = 3000
    },
    FURTO = {
      enabled = true,
      name = 'Furto',
      durationSeconds = 1800
    },
    EXTORSAO = {
      enabled = true,
      name = 'Extorsão',
      durationSeconds = 2400
    },
    ASSALTO_BANCO_JOALHERIA = {
      enabled = true,
      name = 'Assalto a banco ou joalheria',
      durationSeconds = 7200
    },
    ASSALTO_CAIXA_ELETRONICO = {
      enabled = true,
      name = 'Assalto a caixa eletrônico',
      durationSeconds = 3000
    },
    ASSALTO_LOJA = {
      enabled = true,
      name = 'Assalto a loja',
      durationSeconds = 3000
    },
    VEICULO_CLONADO = {
      enabled = true,
      name = 'Veículo clonado',
      durationSeconds = 1800
    },
    RECEPTACAO = {
      enabled = true,
      name = 'Receptação',
      durationSeconds = 1200
    },
    VANDALISMO = {
      enabled = true,
      name = 'Vandalismo',
      durationSeconds = 1800
    },
    PORTE_ARMA_BAIXO_CALIBRE = {
      enabled = true,
      name = 'Porte ilegal de arma de baixo calibre',
      durationSeconds = 2400
    },
    PORTE_ARMA_ALTO_CALIBRE = {
      enabled = true,
      name = 'Porte ilegal de arma de alto calibre',
      durationSeconds = 4800
    },
    TRAFICO_ARMAS = {
      enabled = true,
      name = 'Tráfico de armas',
      durationSeconds = 4800
    },
    TRAFICO_MUNICOES = {
      enabled = true,
      name = 'Tráfico de munições',
      durationSeconds = 4800
    },
    PORTE_ITENS_ARRUMBAMENTO = {
      enabled = true,
      name = 'Porte de itens de arrombamento',
      durationSeconds = 1200
    },
    TRAFICO_DROGAS = {
      enabled = true,
      name = 'Tráfico de drogas',
      durationSeconds = 4800
    },
    ASSOCIACAO_TRAFICO = {
      enabled = true,
      name = 'Associação ao tráfico',
      durationSeconds = 4800
    },
    CORRUPCAO_PASSIVA = {
      enabled = true,
      name = 'Corrupção passiva',
      durationSeconds = 7200
    },
    CORRUPCAO_ATIVA = {
      enabled = true,
      name = 'Corrupção ativa',
      durationSeconds = 7200
    },
    DESACATO = {
      enabled = true,
      name = 'Desacato',
      durationSeconds = 1200
    },
    ABUSO_PODER = {
      enabled = true,
      name = 'Abuso de poder',
      durationSeconds = 3600
    },
    FALSIDADE_IDEOLOGICA = {
      enabled = true,
      name = 'Falsidade ideológica',
      durationSeconds = 1800
    },
    SUBORNO = {
      enabled = true,
      name = 'Suborno',
      durationSeconds = 2400
    },
    FORMACAO_QUADRILHA = {
      enabled = true,
      name = 'Formação de quadrilha',
      durationSeconds = 3000
    },
    ORGANIZACAO_CRIMINOSA = {
      enabled = true,
      name = 'Organização criminosa',
      durationSeconds = 4800
    },
    LAVAGEM_DINHEIRO = {
      enabled = true,
      name = 'Lavagem de dinheiro',
      durationSeconds = 4800
    },
    TENTATIVA_FUGA = {
      enabled = true,
      name = 'Tentativa de fuga',
      durationSeconds = 1800
    },
    RESISTENCIA_PRISAO = {
      enabled = true,
      name = 'Resistência à prisão',
      durationSeconds = 1200
    },
    DESOBEDIENCIA = {
      enabled = true,
      name = 'Desobediência',
      durationSeconds = 600
    },
    PERJURIO = {
      enabled = true,
      name = 'Perjúrio',
      durationSeconds = 1800
    },
    PLANTAR_PROVAS = {
      enabled = true,
      name = 'Plantar provas',
      durationSeconds = 3000
    },
    DIRECAO_PERIGOSA = {
      enabled = true,
      name = 'Direção perigosa',
      durationSeconds = 1200
    },
    CORRIDA_ILEGAL = {
      enabled = true,
      name = 'Corrida ilegal',
      durationSeconds = 2400
    },
    PORTE_MASCARA = {
      enabled = true,
      name = 'Porte de máscara',
      durationSeconds = 600
    },
    DINHEIRO_SUJO = {
      enabled = true,
      name = 'Dinheiro sujo',
      durationSeconds = 1800
    },
    COLETE_BALISTICO_IRREGULAR = {
      enabled = true,
      name = 'Colete balístico irregular',
      durationSeconds = 1800
    },
  },

  -- Reducao manual (capability reports.approve) sem regra aprovada: permanece desligada.
  -- A reducao operacional vem das atividades (jobs.reductionSeconds).
  reductionRulesEnabled = false,
  reductionRules = {},

  -- Soltura manual de staging (server-side, capability reports.approve).
  manualReleaseEnabled = true,
  manualReleaseReasons = {
    staging_release = { enabled = true, label = 'Liberação de staging' }
  },

  -- Staging: rotina habilitada no patio de Bolingbroke. Confirme o ponto no MLO.
  jobsEnabled = true,
  activityRateLimit = { maximum = 6, windowMs = 60000 },
  jobs = {
    rotina = {
      enabled = true,
      durationSeconds = 45,
      reductionSeconds = 30,
      maximumCompletionsPerSentence = 4,
      maximumReductionSecondsPerSentence = 120,
      cooldownSeconds = 20,
      points = {
        bolingbroke_yard = {
          enabled = true,
          coords = { x = 1691.65, y = 2564.11, z = 45.56 },
          radius = 3.0,
          routingBucket = 0,
          drawDistance = 12.0,
          label = '[E] Rotina prisional',
          marker = { enabled = true, type = 1 },
          blip = { enabled = true, sprite = 407, color = 2, scale = 0.7, label = 'Rotina prisional' }
        }
      }
    },
    -- Bloqueadas: falta coordenada real por posto (coords/radius/routingBucket).
    limpeza = { enabled = false, points = {} },
    cozinha = { enabled = false, points = {} },
    lavanderia = { enabled = false, points = {} },
    manutencao = { enabled = false, points = {} }
  }
}
