"""Testes de segurança/configuração sem depender do Android. python3 tests/test_tamp.py"""
import os, pathlib, subprocess, tempfile, unittest, shutil, hashlib
SOURCE=pathlib.Path(__file__).resolve().parents[1]/'lib/tamp.sh'
class TampTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory(); self.root=pathlib.Path(self.tmp.name)
  self.prefix=self.root/'prefix'; self.prefix.mkdir()
  for name in 'mpm_prefork authn_core authz_core authz_host mime dir alias rewrite log_config unixd ssl socache_shmcb'.split():
   f=self.prefix/f'libexec/apache2/mod_{name}.so'; f.parent.mkdir(parents=True,exist_ok=True); f.touch()
  (self.prefix/'libexec/libphp.so').touch()
  self.pma=self.prefix/'share/phpmyadmin'; self.pma.mkdir(parents=True); (self.pma/'index.php').touch()
  self.target=self.prefix/'etc/phpmyadmin/config.inc.php'; self.target.parent.mkdir(parents=True); self.target.write_text('original')
  (self.pma/'config.inc.php').symlink_to(self.target)
 def tearDown(self): self.tmp.cleanup()
 def runbash(self,body):
  env=dict(os.environ, PREFIX=str(self.prefix), TESTROOT=str(self.root), PMA=str(self.pma))
  setup=f'''set -Eeuo pipefail
source '{SOURCE}'
BASE="$TESTROOT/base"; APP="$PREFIX/share/tamp"; CONF="$BASE/config"; RUN="$BASE/run"; LOG="$BASE/log"; BACKUPS="$BASE/backups"
ROOT="$TESTROOT/projects"; PROFILE=local; TLS=off
mkdir -p "$CONF"
dpkg() {{ printf '%s/index.php\\n' "$PMA"; }}
'''
  return subprocess.run(['bash','-c',setup+body],env=env,text=True,capture_output=True)
 def test_local_and_lan_admin_restrictions(self):
  r=self.runbash('generate "$TESTROOT/local.conf"; PROFILE=lan; generate "$TESTROOT/lan.conf"')
  self.assertEqual(r.returncode,0,r.stderr)
  local=(self.root/'local.conf').read_text(); lan=(self.root/'lan.conf').read_text()
  self.assertIn('Listen 127.0.0.1:8080',local); self.assertIn('Listen 0.0.0.0:8080',lan)
  self.assertEqual(lan.count('Require local'),2); self.assertIn('Require all denied',local)
  self.assertNotIn('Require all granted\n</Directory>\n<Directory />',local)
 def test_config_failure_restores_files(self):
  r=self.runbash('''lock() { :; }
httpd() { return 1; }
printf old > "$CONF/httpd.conf"
printf oldsettings > "$CONF/settings"
configure
''')
  self.assertNotEqual(r.returncode,0)
  self.assertEqual((self.root/'base/config/httpd.conf').read_text(),'old')
  self.assertEqual((self.root/'base/config/settings').read_text(),'oldsettings')
  self.assertEqual(self.target.read_text(),'original')
 def test_success_and_secret_stability(self):
  r=self.runbash('''lock() { :; }
httpd() { return 0; }
php() { return 0; }
configure
cp "$CONF/pma-secret" "$TESTROOT/secret"
configure
cmp "$CONF/pma-secret" "$TESTROOT/secret"
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual(len((self.root/'secret').read_text()),32)
  self.assertIn("['AllowRoot'] = true",self.target.read_text())
  self.assertIn("['host'] = '127.0.0.1'",self.target.read_text())
  self.assertIn("['AllowNoPassword'] = false",self.target.read_text())
  self.assertEqual((self.root/'base/config/phpmyadmin.original').read_text(),'original')
 def test_start_controls_both_services(self):
  r=self.runbash('''SERVICES="$BASE/services"
require_install() { :; }; httpd() { :; }; supervise() { :; }
sv() { printf '%s\\n' "$*" >> "$TESTROOT/calls"; }
curl() { :; }; mariadb-admin() { :; }
service_action start
''')
  self.assertEqual(r.returncode,0,r.stderr)
  calls=(self.root/'calls').read_text(); self.assertIn('services/mariadb',calls); self.assertIn('services/apache',calls)
 def test_incompatible_pma_leaves_original(self):
  (self.pma/'config.inc.php').unlink(); (self.pma/'config.inc.php').write_text('independent')
  r=self.runbash('generate "$TESTROOT/config"')
  self.assertNotEqual(r.returncode,0); self.assertEqual(self.target.read_text(),'original')
 def test_sql_password_stays_on_stdin(self):
  r=self.runbash('''require_install() { :; }
admin_socket() { printf '%s\\n' "$*" > "$TESTROOT/args"; cat > "$TESTROOT/sql"; }
PASSWORD_SOURCE=-
configure_root <<'INPUT'
secret'quote\\123
INPUT
''')
  self.assertEqual(r.returncode,0,r.stderr)
  sql=(self.root/'sql').read_text(); self.assertIn("secret''quote\\123",sql)
  self.assertNotIn('secret',(self.root/'args').read_text()); self.assertNotIn('secret',r.stdout)
  self.assertIn("ALTER USER 'root'@'localhost'",sql)
  self.assertIn('unix_socket OR mysql_native_password',sql)
  self.assertNotIn('CREATE USER',sql); self.assertNotIn('GRANT ',sql)
 def service_setup(self):
  return '''SERVICES="$BASE/services"
require_install() { :; }; supervise() { :; }
httpd() { printf 'httpd\\n' >> "$TESTROOT/checks"; }
sv() { printf '%s\\n' "$*" >> "$TESTROOT/calls"; }
curl() { printf 'apache\\n' >> "$TESTROOT/checks"; }
mariadb-admin() { printf 'mariadb\\n' >> "$TESTROOT/checks"; }
'''
 def test_selected_service_is_independent(self):
  for name,other in [('mariadb','apache'),('apache','mariadb')]:
   with self.subTest(name=name):
    r=self.runbash(self.service_setup()+f'service_action start {name}')
    self.assertEqual(r.returncode,0,r.stderr)
    calls=(self.root/'calls').read_text(); checks=(self.root/'checks').read_text()
    self.assertIn('services/'+name,calls); self.assertNotIn('services/'+other,calls)
    self.assertIn(name,checks); self.assertNotIn(other,checks)
    if name=='mariadb': self.assertNotIn('httpd',checks)
    (self.root/'calls').unlink(); (self.root/'checks').unlink()
 def test_invalid_target_does_not_control_services(self):
  r=self.runbash(self.service_setup()+'service_action start invalid')
  self.assertNotEqual(r.returncode,0); self.assertFalse((self.root/'calls').exists())
 def test_supervisor_failure_aborts_start(self):
  r=self.runbash(self.service_setup()+'''supervise() { return 1; }
service_action start mariadb
''')
  self.assertNotEqual(r.returncode,0); self.assertFalse((self.root/'calls').exists())
 def test_health_failure_still_checks_other_service(self):
  r=self.runbash(self.service_setup()+'''mariadb-admin() { return 1; }
sleep() { :; }
service_action start all
''')
  self.assertNotEqual(r.returncode,0)
  self.assertIn('services/apache',(self.root/'calls').read_text())
  self.assertIn('Apache responde',r.stdout)
 def test_restart_single_and_stop_order(self):
  r=self.runbash(self.service_setup()+'''service_action restart apache
mkdir -p "$SERVICES/apache" "$SERVICES/mariadb"
health() { return 1; }; service_pids() { :; }
service_action stop all
''')
  self.assertEqual(r.returncode,0,r.stderr)
  calls=(self.root/'calls').read_text()
  self.assertIn('restart ',calls)
  self.assertLess(calls.index('down '+str(self.root/'base/services/apache')),calls.index('down '+str(self.root/'base/services/mariadb')))
 def test_stale_fifo_is_not_readiness(self):
  r=self.runbash('''SERVICES="$BASE/services"
mkdir -p "$SERVICES/apache/supervise" "$LOG"
mkfifo "$SERVICES/apache/supervise/control"
sv() { [[ -f $TESTROOT/ready ]]; }
runsvdir() { :; }; runsv() { :; }
nohup() { touch "$TESTROOT/launched" "$TESTROOT/ready"; }
supervise apache
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertTrue((self.root/'launched').exists())
 def test_waits_for_every_selected_supervisor(self):
  r=self.runbash('''SERVICES="$BASE/services"
mkdir -p "$LOG"
sv() { [[ $2 == */apache || -f $TESTROOT/ready ]]; }
runsvdir() { :; }; runsv() { :; }
nohup() { touch "$TESTROOT/launched" "$TESTROOT/ready"; }
supervise mariadb apache
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertTrue((self.root/'launched').exists())
 def test_mariadb_doctor_needs_no_http(self):
  r=self.runbash(self.service_setup()+'doctor mariadb')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual((self.root/'checks').read_text().strip(),'mariadb')
 def test_cli_help_without_termux(self):
  for args in [[],['--help'],['--version']]:
   r=self.runbash('unset PREFIX; main '+ ' '.join(args))
   self.assertEqual(r.returncode,0,r.stderr)
 def test_cli_invalid_arguments_fail_before_init(self):
  for args in ['menu','--start --service','--start apache extra','profile','ssl maybe','uninstall','user --name a','install --bad']:
   r=self.runbash('init() { echo UNEXPECTED; }; main '+args)
   self.assertEqual(r.returncode,2,r.stderr)
   self.assertNotIn('UNEXPECTED',r.stdout)
 def test_cli_routes_options(self):
  r=self.runbash('''init() { :; }
service_action() { printf '%s/%s' "$1" "$2"; }
main --start --service mariadb
''')
  self.assertEqual(r.stdout,'start/mariadb'); self.assertEqual(r.returncode,0,r.stderr)
 def test_cli_config_values(self):
  r=self.runbash('''init() { :; }; require_install() { :; }
configure() { printf '%s/%s\\n' "$PROFILE" "$TLS"; }
main profile lan
main ssl off
''')
  self.assertEqual(r.returncode,0,r.stderr); self.assertIn('lan/off',r.stdout)
 def test_uninstall_restore_preserve_and_purge(self):
  for purge in ['0','1']:
   r=self.runbash('''BASE="$PREFIX/var/lib/tamp"; CONF="$BASE/config"; BACKUPS="$BASE/backups"
APP="$PREFIX/share/tamp"; SERVICES="$BASE/services"; DATA="$BASE/mysql"
mkdir -p "$CONF" "$APP" "$DATA" "$BACKUPS/legacy-commands" "$PREFIX/bin" "$ROOT"
printf keep > "$ROOT/project.php"
printf data > "$DATA/test"
printf original > "$CONF/phpmyadmin.original"
printf managed > "$CONF/phpmyadmin.managed"
printf managed > "$PREFIX/etc/phpmyadmin/config.inc.php"
printf '# managed-by-tamp-1\\n' > "$PREFIX/bin/tamp"
printf legacy > "$BACKUPS/legacy-commands/tamp"
PURGE_DATA='''+purge+'''; REMOVE_PACKAGES=0
uninstall
[[ -f $ROOT/project.php && ! -e $APP ]]
[[ $(cat "$PREFIX/bin/tamp") == legacy ]]
[[ $(cat "$PREFIX/etc/phpmyadmin/config.inc.php") == original ]]
''')
   self.assertEqual(r.returncode,0,r.stderr)
   self.assertEqual((self.prefix/'var/lib/tamp/mysql/test').exists(),purge=='0')
 def test_uninstall_aborts_if_stop_fails(self):
  r=self.runbash('''SERVICES="$BASE/services"; PURGE_DATA=1; REMOVE_PACKAGES=0
mkdir -p "$SERVICES/apache" "$SERVICES/mariadb" "$APP"
supervise() { :; }; sv() { return 1; }; health() { return 0; }
uninstall
''')
  self.assertNotEqual(r.returncode,0)
  self.assertTrue((self.root/'base/services/apache').exists())
 def test_remove_packages_rejects_unrelated_dependents(self):
  r=self.runbash('''SERVICES="$BASE/services"; PURGE_DATA=0; REMOVE_PACKAGES=1
printf 'apache2\\n' > "$BASE/packages-added"
dpkg-query() { printf 'install ok installed'; }
apt-get() { [[ $1 == -s ]] || { touch "$TESTROOT/removed"; return; }; printf 'Remv apache2 [1]\\nRemv unrelated [1]\\n'; }
uninstall
''')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'removed').exists())
 def test_stop_recovers_after_supervisor_race(self):
  r=self.runbash('''SERVICES="$BASE/services"
mkdir -p "$SERVICES/apache"
supervisor_ready() { return 0; }
sv() { return 1; }
service_pids() { :; }; health() { return 1; }
stop_service apache
[[ -f $SERVICES/apache/down ]]
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertIn('apache parado',r.stdout)
 def test_stop_fails_when_server_still_responds(self):
  r=self.runbash('''SERVICES="$BASE/services"
mkdir -p "$SERVICES/mariadb"
supervisor_ready() { return 1; }
service_pids() { :; }; health() { return 0; }
stop_service mariadb
''')
  self.assertNotEqual(r.returncode,0)
 def test_user_creation_command_removed(self):
  r=self.runbash('init() { echo UNEXPECTED; }; main user --name test')
  self.assertEqual(r.returncode,2)
  self.assertNotIn('UNEXPECTED',r.stdout)
  self.assertNotRegex(SOURCE.read_text(), r'(?m)^CREATE USER\s')
 def test_install_generates_isolated_daemons_and_tcp(self):
  r=self.runbash('''SERVICES="$BASE/services"; DATA="$BASE/mysql"
SCRIPT_DIR='''+str(SOURCE.parent.parent)+'''
mkdir -p "$PREFIX/bin"
packages() { :; }; configure() { :; }; php() { :; }
mariadb-install-db() { :; }
install
bash -n "$SERVICES/apache/run"
bash -n "$SERVICES/mariadb/run"
''')
  self.assertEqual(r.returncode,0,r.stderr)
  for name in ['apache','mariadb']:
   run=(self.root/f'base/services/{name}/run').read_text()
   self.assertIn('/bin/setsid',run)
   self.assertIn('$previous',run)
  run=(self.root/'base/services/mariadb/run').read_text()
  self.assertIn('--bind-address=127.0.0.1 --port=3306',run)
  self.assertNotIn('--skip-networking',run)
 @unittest.skipUnless(shutil.which('cc'), 'Compilador C indisponível')
 def test_stop_real_orphan_preserves_unrelated_process(self):
  if int(os.readlink('/proc/self')) != os.getpid():
   self.skipTest('/proc usa namespace de PIDs diferente neste ambiente')
  binary=self.prefix/'bin/httpd'; binary.parent.mkdir(exist_ok=True)
  code=self.root/'daemon.c'
  code.write_text('#include <unistd.h>\nint main(void){for(;;)pause();}\n')
  subprocess.run(['cc',str(code),'-o',str(binary)],check=True,capture_output=True)
  conf=self.root/'base/config/httpd.conf'
  own=subprocess.Popen([str(binary),'-f',str(conf),'-DFOREGROUND'])
  other=subprocess.Popen([str(binary),'-f',str(self.root/'other.conf'),'-DFOREGROUND'])
  try:
   r=self.runbash('''SERVICES="$BASE/services"
mkdir -p "$SERVICES/apache"
supervisor_ready() { return 1; }; health() { return 1; }
stop_service apache
''')
   self.assertEqual(r.returncode,0,r.stderr)
   self.assertEqual(own.wait(timeout=3),-15)
   self.assertIsNone(other.poll())
  finally:
   for proc in [own,other]:
    if proc.poll() is None: proc.terminate()
    proc.wait(timeout=3)
 def test_admin_socket_rejects_anonymous_identity(self):
  r=self.runbash('''auth_probe() { printf '@localhost\\n1\\n'; }
mariadb() { touch "$TESTROOT/executed"; }
admin_socket --execute 'SELECT 1'
''')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'executed').exists())
 def test_admin_socket_requires_privilege(self):
  r=self.runbash('''auth_probe() { printf '%s@localhost\\n0\\n' "$1"; }
mariadb() { touch "$TESTROOT/executed"; }
admin_socket --execute 'SELECT 1'
''')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'executed').exists())
 def test_admin_socket_uses_verified_account(self):
  r=self.runbash('''auth_probe() { printf '%s@localhost\\n1\\n' "$1"; }
mariadb() { printf '%s\\n' "$*" > "$TESTROOT/args"; }
admin_socket --execute 'SELECT 1'
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertIn('-u root',(self.root/'args').read_text())
 def test_failed_root_update_never_prints_sql_password(self):
  r=self.runbash('''require_install() { :; }
admin_socket() { cat >&2; printf 'SQL failure\\n' >&2; return 1; }
PASSWORD_SOURCE=-
configure_root <<'INPUT'
private-password-123
INPUT
''')
  self.assertNotEqual(r.returncode,0)
  self.assertNotIn('private-password-123',r.stdout+r.stderr)
  self.assertNotIn('ALTER USER',r.stdout+r.stderr)
  self.assertIn('tamp db-auth',r.stderr)
 def test_recovery_files_contain_hash_not_literal_password(self):
  r=self.runbash('''mkdir -p "$TESTROOT/private"
PASSWORD='private-test-password'
recovery_files "$TESTROOT/private"
''')
  self.assertEqual(r.returncode,0,r.stderr)
  sql=(self.root/'private/init.sql').read_text()
  expected=hashlib.sha1(hashlib.sha1(b'private-test-password').digest()).hexdigest().upper()
  self.assertIn('*'+expected,sql)
  self.assertNotIn('private-test-password',sql)
  self.assertNotIn('CREATE USER',sql)
  self.assertIn('GRANT ALL PRIVILEGES',sql)
  self.assertEqual((self.root/'private/client.cnf').stat().st_mode & 0o777,0o600)
 def recovery_setup(self):
  return '''SERVICES="$BASE/services"; DATA="$BASE/mysql"
mkdir -p "$DATA"
printf original-data > "$DATA/test"
require_install() { :; }; lock() { :; }; flock() { :; }
stop_service() { printf stop >> "$TESTROOT/order"; }
setsid() { printf '%s\\n' "$*" > "$TESTROOT/server-args"; }
recovery_shutdown() { :; }
service_action() { printf start >> "$TESTROOT/order"; }
mariadb() {
 case "$*" in *--protocol=socket*) printf 'root@localhost\\n1\\n';;
 *) printf 'root@localhost\\n';; esac
}
PASSWORD_SOURCE=-
'''
 def test_recovery_preserves_data_and_verifies_tcp(self):
  r=self.runbash(self.recovery_setup()+'''recover_root <<'INPUT'
private-test-password
INPUT
''')
  self.assertEqual(r.returncode,0,r.stderr)
  self.assertEqual((self.root/'order').read_text(),'stopstart')
  self.assertEqual((self.root/'base/mysql/test').read_text(),'original-data')
  self.assertEqual(len(list((self.root/'base/backups').glob('*/mysql/test'))),1)
  args=(self.root/'server-args').read_text()
  self.assertIn('--skip-networking',args)
  self.assertNotIn('--skip-grant-tables',args)
  self.assertNotIn('private-test-password',args+r.stdout+r.stderr)
  self.assertFalse(list((self.root/'base/run').rglob('client.cnf')))
 def test_recovery_aborts_when_stop_fails(self):
  r=self.runbash(self.recovery_setup()+'''stop_service() { return 1; }
recover_root <<'INPUT'
private-test-password
INPUT
''')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'server-args').exists())
 def test_recovery_aborts_when_backup_fails(self):
  r=self.runbash(self.recovery_setup()+'''cp() { return 1; }
recover_root <<'INPUT'
private-test-password
INPUT
''')
  self.assertNotEqual(r.returncode,0)
  self.assertFalse((self.root/'server-args').exists())
if __name__=='__main__': unittest.main()
