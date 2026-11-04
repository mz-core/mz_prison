fx_version 'cerulean'
game 'gta5'

name 'mz_prison'
author 'Mazus / MZ Framework'
description 'Canonical prison sentence and retained-property domain for MZ Framework'
version '0.3.0'

lua54 'yes'

shared_scripts { 'config.lua' }

client_scripts {
  'client/release.lua',
  'client/status.lua',
  'client/interactions.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/bridge.lua',
  'server/prepare.lua',
  'server/repository.lua',
  'server/service.lua',
  'server/events.lua',
  'server/exports.lua',
  'server/main.lua'
}

dependencies {
  'oxmysql',
  'mz_core',
  'mz_inventory',
  'mz_interact',
  'mz_menu'
}
