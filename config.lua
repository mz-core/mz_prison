MZPrisonConfig = {
  clockMode = 'online',
  tickSeconds = 30,

  -- Coordenadas reais e regras legais devem ser aprovadas pelo operador.
  intakeEnabled = false,
  intakeMaximumDistance = 3.0,
  intakePoints = {},
  releasePoints = {},

  sentenceRulesEnabled = false,
  legalVersion = 'unapproved',
  jurisdictions = {},
  sentenceRules = {},

  reductionRulesEnabled = false,
  reductionRules = {},

  manualReleaseEnabled = false,
  manualReleaseReasons = {},

  jobsEnabled = false,
  activityRateLimit = {},
  jobs = {}
}
