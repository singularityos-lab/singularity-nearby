project('singularity-nearby', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

add_project_arguments('-DGETTEXT_PACKAGE="singularity-nearby"', language: 'c')

glib_dep = dependency('glib-2.0')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
json_dep = dependency('json-glib-1.0')
gee_dep = dependency('gee-0.8')
soup_dep = dependency('libsoup-3.0')
gnutls_dep = dependency('gnutls', version: '>= 3.6')
posix_dep = meson.get_compiler('vala').find_library('posix')

build_conf = configuration_data()
build_conf.set('SYSCONFDIR', get_option('prefix') / get_option('sysconfdir'))
build_conf.set('VERSION', meson.project_version())
build_config = configure_file(
  input: 'src/build_config.vala.in',
  output: 'build_config.vala',
  configuration: build_conf,
)

helpers = static_library('nearby-helpers', 'src/certs.c', 'src/netif.c',
  dependencies: [glib_dep, gio_dep, gnutls_dep],
)

vala_args = ['--vapidir=' + meson.current_source_dir() / 'src', '--pkg=certs', '--pkg=netif']
deps = [glib_dep, gio_dep, gio_unix_dep, json_dep, gee_dep, posix_dep, soup_dep]

core_sources = [build_config] + files(
  'src/packet.vala',
  'src/config.vala',
  'src/mdns.vala',
  'src/link.vala',
  'src/lan.vala',
  'src/device.vala',
  'src/transfers.vala',
  'src/history.vala',
  'src/sinty_ai.vala',
)

service_sources = core_sources + files(
    'src/desktop.vala',
    'src/media.vala',
    'src/obex.vala',
    'src/service.vala',
    'src/collab.vala',
    'src/relay.vala',
)

executable('singularity-nearby',
  service_sources + files('src/main.vala'),
  dependencies: deps,
  link_with: helpers,
  include_directories: include_directories('src'),
  vala_args: vala_args,
  c_args: ['-DG_LOG_DOMAIN="singularity-nearby"'],
  install: true,
  install_dir: get_option('libexecdir'),
)

service_conf = configuration_data()
service_conf.set('libexecdir', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/dev.sinty.Nearby.service.in',
  output: 'dev.sinty.Nearby.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)
if get_option('autostart')
  configure_file(
    input: 'data/dev.sinty.Nearby.desktop.in',
    output: 'dev.sinty.Nearby.desktop',
    configuration: service_conf,
    install: true,
    install_dir: get_option('sysconfdir') / 'xdg' / 'autostart',
    install_tag: 'runtime',
  )
endif
install_data('data/nearby.conf', install_dir: get_option('sysconfdir') / 'singularity')
install_data('data/dev.sinty.Collab1.ini', install_dir: get_option('datadir') / 'singularity' / 'capabilities')

packet_test = executable('nearby-packet-test',
  core_sources + files('tests/packet_test.vala'),
  dependencies: deps,
  link_with: helpers,
  include_directories: include_directories('src'),
  vala_args: vala_args,
)
test('nearby-packet', packet_test, env: ['TMPDIR=' + meson.current_build_dir()])

collab_test = executable('nearby-collab-test',
  service_sources + files('tests/collab_test.vala'),
  dependencies: deps,
  link_with: helpers,
  include_directories: include_directories('src'),
  vala_args: vala_args,
)
test('nearby-collab', find_program('dbus-run-session'),
  args: ['--', collab_test],
  env: ['TMPDIR=' + meson.current_build_dir()],
)

link_test = executable('nearby-link-test',
  service_sources + files('tests/link_test.vala'),
  dependencies: deps,
  link_with: helpers,
  include_directories: include_directories('src'),
  vala_args: vala_args,
)
test('nearby-link', find_program('dbus-run-session'),
  args: ['--', link_test],
  env: ['TMPDIR=' + meson.current_build_dir()],
)
