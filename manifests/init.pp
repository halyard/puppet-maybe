# @summary Configure Maybe instance
#
# @param hostname is the service hostname
# @param aws_access_key_id sets the AWS key to use for Route53 challenge
# @param aws_secret_access_key sets the AWS secret key to use for the Route53 challenge
# @param email sets the contact address for the certificate
# @param secret_key_base sets the Rails cookie secret
# @param database_password sets the postgres password
# @param datadir sets the storage location on disk
# @param container_ip sets the IP for the service container
# @param postgres_ip sets the IP for the database docker container
# @param backup_target sets the target repo for backups
# @param backup_database_watchdog sets the watchdog URL to confirm backups are working
# @param backup_password sets the encryption key for backup snapshots
# @param backup_environment sets the env vars to use for backups
# @param backup_rclone sets the config for an rclone backend
# @param postgres_watchdog sets the watchdog URL for postgres dumps
class maybe (
  String $hostname,
  String $aws_access_key_id,
  String $aws_secret_access_key,
  String $email,
  String $secret_key_base,
  String $database_password,
  String $datadir = '/opt/maybe',
  String $container_ip = '172.17.0.2',
  String $postgres_ip = '172.17.0.3',
  Optional[String] $backup_target = undef,
  Optional[String] $backup_database_watchdog = undef,
  Optional[String] $backup_password = undef,
  Optional[Hash[String, String]] $backup_environment = undef,
  Optional[String] $backup_rclone = undef,
  Optional[String] $postgres_watchdog = undef,
) {
  file { [
      $datadir,
      "${datadir}/data",
      "${datadir}/backup",
      "${datadir}/postgres",
    ]:
      ensure => directory,
  }

  docker::container { 'maybe':
    image => 'ghcr.io/maybe-finance/maybe:latest',
    args  => [
      "--ip ${container_ip}",
      "-v ${datadir}/data:/rails/storage",
      '-e SELF_HOSTED=true',
      '-e RAILS_FORCE_SSL=false',
      '-e RAILS_ASSUME_SSL=false',
      '-e GOOD_JOB_EXECUTION_MODE=async',
      "-e SECRET_KEY_BASE=${secret_key_base}",
      "-e DB_HOST=${postgres_ip}",
      '-e POSTGRES_DB=maybe_production',
      '-e POSTGRES_USER=maybe_user',
      "-e POSTGRES_PASSWORD=${database_password}",
    ],
    cmd   => '',
  }

  nginx::site { $hostname:
    proxy_target          => "http://${container_ip}:3000",
    aws_access_key_id     => $aws_access_key_id,
    aws_secret_access_key => $aws_secret_access_key,
    email                 => $email,
  }

  firewall { '101 allow cross container from maybe to postgres':
    chain       => 'FORWARD',
    action      => 'accept',
    proto       => 'tcp',
    source      => $container_ip,
    destination => $postgres_ip,
    dport       => 5432,
  }

  docker::container { 'postgres':
    image   => 'postgres:17',
    args    => [
      "--ip ${postgres_ip}",
      "-v ${datadir}/postgres:/var/lib/postgresql/data",
      '-e POSTGRES_USER=maybe_user',
      "-e POSTGRES_PASSWORD=${database_password}",
      '-e POSTGRES_DB=maybe_production',
    ],
    cmd     => '-c ssl=on -c ssl_cert_file=/etc/ssl/certs/ssl-cert-snakeoil.pem -c ssl_key_file=/etc/ssl/private/ssl-cert-snakeoil.key',
    require => File["${datadir}/postgres"],
  }

  file { '/usr/local/bin/maybe-backup.sh':
    ensure => file,
    source => 'puppet:///modules/maybe/maybe-backup.sh',
    mode   => '0755',
  }

  file { '/etc/systemd/system/maybe-backup.service':
    ensure  => file,
    content => template('maybe/maybe-backup.service.erb'),
    notify  => Service['maybe-backup.timer'],
  }

  file { '/etc/systemd/system/maybe-backup.timer':
    ensure => file,
    source => 'puppet:///modules/maybe/maybe-backup.timer',
    notify => Service['maybe-backup.timer'],
  }

  service { 'maybe-backup.timer':
    ensure => running,
    enable => true,
  }

  tidy { "${datadir}/backup weekly":
    path    => "${datadir}/backup",
    age     => '100d',
    recurse => true,
    matches => 'dump_??????{01,07,14,21,28}-??????.sql',
  }

  tidy { "${datadir}/backup all":
    path    => "${datadir}/backup",
    age     => '14d',
    recurse => true,
    matches => 'dump_*.sql',
  }

  if $backup_target != '' {
    backup::repo { 'maybe-database':
      source        => "${datadir}/backup",
      target        => "${backup_target}/database",
      watchdog_url  => $backup_database_watchdog,
      password      => $backup_password,
      environment   => $backup_environment,
      rclone_config => $backup_rclone,
    }
  }
}
