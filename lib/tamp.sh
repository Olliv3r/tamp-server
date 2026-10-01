#!/usr/bin/env bash
VERSION=1.3.2
msg() { printf '%s[%s]%s %s\n' "${C:-}" "$1" "${R:-}" "$2"; }
fail() { msg ERRO "$*" >&2; return 1; }
init() {
 : "${PREFIX:?Execute no Termux: PREFIX não definido}"
 [[ -x $PREFIX/bin/pkg && $PREFIX != /usr ]] || { fail 'Ambiente Termux necessário.'; return 1; }
 BASE="$PREFIX/var/lib/tamp"; APP="$PREFIX/share/tamp"; CONF="$BASE/config"; RUN="$BASE/run"
 SERVICES="$BASE/services"; DATA="$BASE/mysql"; LOG="$BASE/log"; BACKUPS="$BASE/backups"
 ROOT="$HOME/htdocs"; PROFILE=local; TLS=off
 if [[ -t 1 && -z ${NO_COLOR+x} ]]; then C=$'\033[1;36m'; R=$'\033[0m'; fi
 if [[ -f $CONF/settings ]]; then
  # Apenas campos de dados; nunca executar arquivo de configuração.
  ROOT=$(sed -n 's/^root=//p' "$CONF/settings")
  PROFILE=$(sed -n 's/^profile=//p' "$CONF/settings")
  TLS=$(sed -n 's/^tls=//p' "$CONF/settings")
 fi
 validate_settings
}
validate_settings() {
 [[ $ROOT == /* && $ROOT != *'"'* && $ROOT != *$'\n'* && $ROOT != *'\\'* ]] || { fail 'Caminho de projetos inválido.'; return 1; }
 [[ $PROFILE == local || $PROFILE == lan ]] || return 1
 [[ $TLS == on || $TLS == off ]] || return 1
}
installed() { [[ -f $CONF/httpd.conf && -f $SERVICES/apache/run ]]; }
require_install() { installed || { fail 'Execute instalar primeiro.'; return 1; }; }
lock() { mkdir -p "$BASE"; exec 9>"$BASE/lock"; flock -n 9 || { fail 'Outra operação TAMP está em andamento.'; return 1; }; }
packages() {
 msg ETAPA 'Atualizando índice de pacotes (sem upgrade geral)...'
 mkdir -p "$BASE"
 local package
 local -a wanted=(apache2 php php-apache phpmyadmin mariadb openssl-tool curl termux-services runit util-linux)
 # Registrar antes da instalação permite desfazer mesmo uma instalação parcial.
 for package in "${wanted[@]}"; do
  if [[ $(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || :) != 'install ok installed' ]]; then
   grep -qxF "$package" "$BASE/packages-added" 2>/dev/null || printf '%s\n' "$package" >> "$BASE/packages-added"
  fi
 done
 pkg update -y
 DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold install "${wanted[@]}"
}
module() {
 local name=$1 file="$PREFIX/libexec/apache2/mod_$1.so"
 [[ -f $file ]] || { fail "Módulo Apache ausente: $file"; return 1; }
 printf 'LoadModule %s_module "%s"\n' "$name" "$file"
}
generate() {
 local out=$1 bind=127.0.0.1 phpmod pma
 [[ $PROFILE == lan ]] && bind=0.0.0.0
 phpmod=$(find "$PREFIX" -name libphp.so -type f -print -quit)
 [[ -n $phpmod ]] || { fail 'libphp.so ausente; verifique php-apache.'; return 1; }
 pma=$(dpkg -L phpmyadmin | sed -n 's@/index.php$@@p' | head -n 1)
 [[ -f $pma/index.php && -f $pma/config.inc.php ]] || { fail 'Layout do phpMyAdmin não reconhecido; nenhuma configuração será aplicada.'; return 1; }
 # O pacote deve delegar config.inc.php ao arquivo em etc; não sobrescrever código do pacote.
 [[ $(readlink -f "$pma/config.inc.php") == "$PREFIX/etc/phpmyadmin/config.inc.php" ]] || {
  fail 'phpMyAdmin não aponta para etc/phpmyadmin/config.inc.php. Verifique o pacote antes de instalar.'; return 1;
 }
 {
 printf 'ServerRoot "%s"\nServerName localhost\nListen %s:8080\n' "$PREFIX" "$bind"
 for m in mpm_prefork authn_core authz_core authz_host mime dir alias rewrite log_config unixd; do module "$m"; done
 printf 'LoadModule php_module "%s"\n' "$phpmod"
 cat <<EOF
PidFile "$RUN/httpd.pid"
DefaultRuntimeDir "$RUN"
ErrorLog "$LOG/apache-error.log"
LogFormat "%h %l %u %t %r %>s %b" common
CustomLog "$LOG/apache-access.log" common
TypesConfig "$PREFIX/etc/apache2/mime.types"
ServerTokens Prod
ServerSignature Off
TraceEnable Off
Timeout 60
DocumentRoot "$ROOT"
DirectoryIndex index.php index.html
<Directory />
 AllowOverride None
 Require all denied
</Directory>
<Directory "$ROOT">
 Options -Indexes -FollowSymLinks -ExecCGI -Includes
 AllowOverride FileInfo
 Require all granted
</Directory>
<FilesMatch "(^\\.|(~$)|\\.(bak|sql|sqlite|db|ini|log|key)$)">
 Require all denied
</FilesMatch>
<FilesMatch "\\.php$">
 SetHandler application/x-httpd-php
</FilesMatch>
php_admin_flag expose_php Off
php_admin_flag display_errors Off
php_admin_flag log_errors On
php_admin_value error_log "$LOG/php-error.log"
php_admin_value mysqli.default_socket "$RUN/mysql.sock"
php_admin_value pdo_mysql.default_socket "$RUN/mysql.sock"
Alias /tamp/ "$APP/web/"
<Directory "$APP/web">
 AllowOverride None
 Options -Indexes
 Require local
</Directory>
Alias /phpmyadmin "$pma"
<Directory "$pma">
 AllowOverride None
 Options -Indexes
 Require local
</Directory>
<LocationMatch "^/phpmyadmin/(setup|test|libraries|templates)(/|$)">
 Require all denied
</LocationMatch>
EOF
 if [[ $TLS == on ]]; then
 module ssl; module socache_shmcb
 cat <<EOF
Listen $bind:8443
SSLSessionCache "shmcb:$RUN/ssl-cache(512000)"
<VirtualHost $bind:8443>
 SSLEngine on
 SSLProtocol -all +TLSv1.2 +TLSv1.3
 SSLCertificateFile "$CONF/tls/server.crt"
 SSLCertificateKeyFile "$CONF/tls/server.key"
</VirtualHost>
EOF
 fi
 } > "$out"
}
configure() (
 set -Eeuo pipefail
 lock
 mkdir -p "$CONF" "$RUN" "$LOG" "$BACKUPS" "$ROOT"
 chmod 700 "$BASE" "$CONF" "$RUN" "$LOG" "$BACKUPS"
 local staging stamp target
 staging=$(mktemp -d "$BASE/.transaction.XXXXXX")
 stamp=$(mktemp -d "$BACKUPS/config-$(date +%Y%m%d-%H%M%S).XXXXXX")
 target="$PREFIX/etc/phpmyadmin/config.inc.php"
 for f in httpd.conf settings; do [[ ! -f $CONF/$f ]] || cp -p "$CONF/$f" "$stamp/$f"; done
 [[ ! -f $target ]] || cp -p "$target" "$stamp/phpmyadmin.php"
 rollback() {
  local rc=$?
  if ((rc)); then
   for f in httpd.conf settings; do
    if [[ -f $stamp/$f ]]; then cp -p "$stamp/$f" "$CONF/$f"; else rm -f "$CONF/$f"; fi
   done
   if [[ -f $stamp/phpmyadmin.php ]]; then cp -p "$stamp/phpmyadmin.php" "$target"; fi
   msg ERRO "Configuração revertida. Backup: $stamp" >&2
  fi
  rm -rf -- "$staging"
 }
 trap rollback EXIT
 generate "$staging/httpd.conf"
 httpd -t -f "$staging/httpd.conf"
 printf 'root=%s\nprofile=%s\ntls=%s\n' "$ROOT" "$PROFILE" "$TLS" > "$staging/settings"
 # Primeiro backup fica permanente para remoção segura.
 if [[ ! -f $CONF/phpmyadmin.original && ! -f $CONF/phpmyadmin.was-absent ]]; then
  if [[ -f $target ]]; then cp -p "$target" "$CONF/phpmyadmin.original"; else touch "$CONF/phpmyadmin.was-absent"; fi
 fi
 local secret
 if [[ -f $CONF/pma-secret ]]; then secret=$(cat "$CONF/pma-secret"); else secret=$(openssl rand -hex 16); printf '%s' "$secret" > "$CONF/pma-secret"; chmod 600 "$CONF/pma-secret"; fi
 cat > "$staging/phpmyadmin.php" <<EOF
<?php
\$cfg['blowfish_secret'] = '$secret';
\$i = 1;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = '127.0.0.1';
\$cfg['Servers'][\$i]['port'] = '3306';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = true;
\$cfg['TempDir'] = '$BASE/pma-tmp';
EOF
 php -l "$staging/phpmyadmin.php"
 mkdir -p "$BASE/pma-tmp"; chmod 700 "$BASE/pma-tmp"
 cp "$staging/httpd.conf" "$CONF/httpd.conf"
 cp "$staging/settings" "$CONF/settings"
 mkdir -p "$(dirname "$target")"; cp "$staging/phpmyadmin.php" "$target"; chmod 600 "$target"
 cp "$target" "$CONF/phpmyadmin.managed"
 msg OK "Configuração validada. Projetos: $ROOT; perfil: $PROFILE; HTTPS: $TLS"
)
install() {
 for cmd in tamp tamp-start tamp-stop tamp-restart tamp-status tamp-doctor tamp-logs; do
  if [[ -e $PREFIX/bin/$cmd ]] && ! rg_marker "$PREFIX/bin/$cmd"; then
   # Comandos legados somente podem ser substituídos com backup e consentimento.
   [[ ${REPLACE_EXISTING:-0} == 1 ]] || { fail "Comando existente: $cmd. Use install --replace-existing para substituir com backup."; return 1; }
   mkdir -p "$BACKUPS/legacy-commands"
   [[ -e $BACKUPS/legacy-commands/$cmd ]] || cp -p "$PREFIX/bin/$cmd" "$BACKUPS/legacy-commands/$cmd"
  fi
 done
 packages
 mkdir -p "$BASE" "$RUN" "$LOG" "$APP/lib" "$APP/web" "$SERVICES/apache" "$SERVICES/mariadb"
 chmod 700 "$BASE"
 if [[ $(readlink -f "$SCRIPT_DIR") != $(readlink -f "$APP") ]]; then
  cp "$SCRIPT_DIR/lib/tamp.sh" "$APP/lib/"
  cp "$SCRIPT_DIR/install.sh" "$APP/install.sh"
  php -l "$SCRIPT_DIR/web/index.php"
  cp "$SCRIPT_DIR/web/index.php" "$APP/web/"
 fi
 php -l "$APP/web/index.php"
 configure
 if [[ ! -d $DATA/mysql ]]; then
  mkdir -p "$DATA"; chmod 700 "$DATA"
  mariadb-install-db --no-defaults --datadir="$DATA" --auth-root-authentication-method=socket
 fi
 cat > "$SERVICES/apache/run" <<EOF
#!$PREFIX/bin/sh
exec 2>>"$LOG/apache-service.log"
if [ -r "$RUN/httpd.pid" ]; then
 read -r previous < "$RUN/httpd.pid"
 case \$previous in ''|*[!0-9]*) ;; *)
  if kill -0 "\$previous" 2>/dev/null; then echo "PID Apache ainda ativo; execute tamp stop apache." >&2; sleep 2; exit 1; fi;;
 esac
fi
exec "$PREFIX/bin/setsid" "$PREFIX/bin/httpd" -f "$CONF/httpd.conf" -DFOREGROUND
EOF
 cat > "$SERVICES/mariadb/run" <<EOF
#!$PREFIX/bin/sh
exec 2>>"$LOG/mariadb-service.log"
if [ -r "$RUN/mysql.pid" ]; then
 read -r previous < "$RUN/mysql.pid"
 case \$previous in ''|*[!0-9]*) ;; *)
  if kill -0 "\$previous" 2>/dev/null; then echo "PID MariaDB ainda ativo; execute tamp stop mariadb." >&2; sleep 2; exit 1; fi;;
 esac
fi
exec "$PREFIX/bin/setsid" "$PREFIX/bin/mariadbd" --no-defaults --datadir="$DATA" --socket="$RUN/mysql.sock" --pid-file="$RUN/mysql.pid" --bind-address=127.0.0.1 --port=3306 --log-error="$LOG/mariadb-error.log"
EOF
 chmod 700 "$SERVICES/"*/run
 touch "$SERVICES/apache/down" "$SERVICES/mariadb/down"
 for cmd in tamp tamp-start tamp-stop tamp-restart tamp-status tamp-doctor tamp-logs; do
  if [[ $cmd == tamp ]]; then action='"$@"'; else action="${cmd#tamp-} \"\$@\""; fi
  cat > "$PREFIX/bin/$cmd" <<EOF
#!$PREFIX/bin/bash
# managed-by-tamp-1
exec "$PREFIX/bin/bash" "$APP/install.sh" $action
EOF
  chmod 700 "$PREFIX/bin/$cmd"
 done
 msg OK 'Instalação concluída. Use tamp start e tamp root --password-file ARQUIVO para configurar root.'
}
select_services() {
 SELECTED=()
 case ${1:-all} in
  all|both|ambos) SELECTED=(mariadb apache);;
  apache|mariadb) SELECTED=("$1");;
  *) fail 'Serviço inválido. Use apache, mariadb ou all.'; return 2;;
 esac
}
supervisor_ready() { sv status "$SERVICES/$1" >/dev/null 2>&1; }
supervise() {
 local name ready=1
 for name in "$@"; do supervisor_ready "$name" || ready=0; done
 ((ready)) && return 0
 for name in runsvdir runsv sv flock nohup setsid; do
  command -v "$name" >/dev/null || { fail "Comando ausente: $name. Execute instalar / reparar."; return 1; }
 done
 mkdir -p "$RUN" "$LOG"
 # O lock dura enquanto runsvdir estiver vivo. FIFOs antigos não provam atividade.
 # Fechar fd 9 impede que o supervisor retenha o lock da operação chamadora.
 # --close impede que runsv e os serviços herdem o lock do supervisor.
 nohup setsid -f flock -n -o "$RUN/supervisor.lock" runsvdir "$SERVICES" >>"$LOG/supervisor.log" 2>&1 9>&- </dev/null &
 for _ in {1..100}; do
  ready=1
  for name in "$@"; do supervisor_ready "$name" || ready=0; done
  ((ready)) && return 0
  sleep .1
 done
 fail 'Supervisor não respondeu em 10s. Execute tamp logs; verifique supervisor.log.'
}
health() {
 case $1 in
  apache) curl -fsS --max-time 2 http://127.0.0.1:8080/tamp/ >/dev/null 2>&1;;
  mariadb) mariadb-admin --no-defaults --connect-timeout=2 --socket="$RUN/mysql.sock" ping >/dev/null 2>&1;;
 esac
}
process_matches() {
 local name=$1 pid=$2 exe argument found=0 i
 local -a argv=()
 [[ $pid =~ ^[0-9]+$ && $pid -gt 1 ]] || return 1
 exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
 mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || return 1
 case $name in
  apache)
   [[ $exe == "$(readlink -f "$PREFIX/bin/httpd")" ]] || return 1
   for ((i=0;i<${#argv[@]}-1;i++)); do
    [[ ${argv[i]} != -f || ${argv[i+1]} != "$CONF/httpd.conf" ]] || found=1
   done;;
  mariadb)
   [[ $exe == "$(readlink -f "$PREFIX/bin/mariadbd")" ]] || return 1
   for argument in "${argv[@]}"; do [[ $argument != "--datadir=$DATA" ]] || found=1; done;;
 esac
 ((found))
}
service_pids() {
 local name=$1 proc pid i
 for proc in /proc/[0-9]*/cmdline; do
  pid=${proc#/proc/}; pid=${pid%/cmdline}
  if process_matches "$name" "$pid"; then printf '%s\n' "$pid"; fi
 done
 return 0
}
stop_service() {
 local name=$1 pid pending=0
 local -a pids=()
 # Persistir down antes de recuperar ou sinalizar processos.
 touch "$SERVICES/$name/down" || return 1
 if supervisor_ready "$name"; then
  sv -w 20 down "$SERVICES/$name" || msg AVISO "$name: supervisor falhou; verificando processos próprios."
 fi
 mapfile -t pids < <(service_pids "$name")
 for pid in "${pids[@]}"; do
  # Nunca sinalizar por nome genérico ou por PID sem conferir executable/configuração.
  if process_matches "$name" "$pid"; then
   kill -TERM "$pid" 2>/dev/null || {
    if process_matches "$name" "$pid"; then fail "Não foi possível sinalizar $name (PID $pid)."; return 1; fi
   }
  fi
 done
 for _ in {1..100}; do
  pending=0
  for pid in "${pids[@]}"; do if process_matches "$name" "$pid"; then pending=1; fi; done
  ((pending)) || break
  sleep .2
 done
 ((pending == 0)) || { fail "$name não encerrou em 20s; dados preservados, sem SIGKILL."; return 1; }
 # Quando /proc não está legível, não declarar parado apenas por não encontrar PID.
 local pidfile="$RUN/mysql.pid" recorded=
 [[ $name != apache ]] || pidfile="$RUN/httpd.pid"
 if [[ -r $pidfile ]]; then
  read -r recorded < "$pidfile" || :
  if [[ $recorded =~ ^[0-9]+$ ]] && kill -0 "$recorded" 2>/dev/null; then
   fail "$name: PID do arquivo ainda existe; não foi possível confirmar a parada."; return 1
  fi
 fi
 if health "$name"; then fail "$name ainda responde; parada não confirmada."; return 1; fi
 msg OK "$name parado."
}
service_action() (
 set -Eeuo pipefail
 require_install
 local action=$1 target=${2:-all} failed=0 name healthy
 select_services "$target"
 lock
 if [[ $action == start || $action == restart ]]; then
  for name in "${SELECTED[@]}"; do
   [[ $name != apache ]] || httpd -t -f "$CONF/httpd.conf"
  done
  supervise "${SELECTED[@]}"
 fi
 # Parar HTTP antes do banco ao selecionar ambos.
 [[ $action != stop || ${#SELECTED[@]} != 2 ]] || SELECTED=(apache mariadb)
 for name in "${SELECTED[@]}"; do
  msg ETAPA "$action: $name"
  if [[ $action == stop ]]; then
   stop_service "$name" || failed=1
   continue
  fi
  case $action in
   start) sv -w 15 up "$SERVICES/$name" || { failed=1; continue; };;
   stop) sv -w 15 down "$SERVICES/$name" || { failed=1; continue; };;
   restart) sv -w 15 restart "$SERVICES/$name" || { failed=1; continue; };;
  esac
  if [[ $action == stop ]]; then msg OK "$name parado."; continue; fi
  healthy=0
  for _ in {1..30}; do
   if health "$name"; then healthy=1; break; fi
   sleep .2
  done
  if ((healthy)); then
   if [[ $name == apache ]]; then msg OK 'Apache responde: http://127.0.0.1:8080/tamp/'
   else msg OK 'MariaDB responde pelo socket. Console: tamp sql'; fi
  else
   fail "$name não respondeu ao teste de saúde. Execute tamp logs $name." || :
   failed=1
  fi
 done
 ((failed == 0)) || { fail "Falha em serviço selecionado. Execute tamp doctor $target e tamp logs $target."; return 1; }
)
status() {
 select_services "${1:-all}"
 local name
 for name in "${SELECTED[@]}"; do
  if supervisor_ready "$name"; then sv status "$SERVICES/$name" || :
  else msg INFO "$name: supervisor inativo (estado do processo não confirmado)"; fi
 done
}
doctor() {
 require_install
 select_services "${1:-all}"
 local failed=0 name
 status "${1:-all}"
 for name in "${SELECTED[@]}"; do
  if [[ $name == apache ]]; then
   httpd -t -f "$CONF/httpd.conf" || failed=1
   php --version | head -n 1
   [[ $TLS != on ]] || openssl x509 -in "$CONF/tls/server.crt" -checkend 604800 -noout || failed=1
  fi
  if health "$name"; then msg OK "$name responde"; else msg AVISO "$name não responde"; failed=1; fi
 done
 msg INFO "Perfil: $PROFILE | projetos: $ROOT | HTTPS: $TLS"
 return "$failed"
}
logs() {
 select_services "${1:-all}"
 local f name
 for f in "$LOG/supervisor.log"; do [[ ! -f $f ]] || { msg LOG "$f"; tail -n 25 "$f"; }; done
 for name in "${SELECTED[@]}"; do
  for f in "$LOG/$name"*.log; do [[ ! -f $f ]] || { msg LOG "$f"; tail -n 25 "$f"; }; done
  [[ $name != apache || ! -f $LOG/php-error.log ]] || { msg LOG "$LOG/php-error.log"; tail -n 25 "$LOG/php-error.log"; }
 done
}
diagnose_http() {
 require_install
 local path=$1 code
 code=$(curl --path-as-is -sS --max-time 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080$path") || { fail 'Não foi possível consultar o Apache.'; return 1; }
 msg INFO "HTTP $code — $path"
 logs apache
 [[ $code != 5* ]] || { fail 'Erro de servidor: consulte as linhas de log acima. Não é possível deduzir a causa só pelo código 500.'; return 1; }
}
sql_console() {
 require_install
 health mariadb || { fail 'MariaDB não responde. Execute tamp start mariadb.'; return 1; }
 msg INFO 'Console local de administração SQL; saia com exit. Não requer root do Android.'
 if [[ ${SQL_PASSWORD:-0} == 1 ]]; then mariadb --no-defaults --socket="$RUN/mysql.sock" -u root -p
 else admin_socket; fi
}
read_password() {
 local source=$1
 PASSWORD=
 if [[ $source == - ]]; then
  [[ ! -t 0 ]] || { fail 'Forneça a senha por stdin redirecionado.'; return 2; }
  IFS= read -r PASSWORD || [[ -n $PASSWORD ]]
 else
  [[ -f $source && -r $source ]] || { fail 'Arquivo de senha inválido.'; return 2; }
  IFS= read -r PASSWORD < "$source" || [[ -n $PASSWORD ]]
 fi
 [[ ${#PASSWORD} -ge 12 ]] || { fail 'Senha precisa de pelo menos 12 caracteres.'; return 2; }
}
auth_probe() {
 mariadb --no-defaults --protocol=socket --socket="$RUN/mysql.sock" -u "$1" --batch --skip-column-names --execute "SELECT CURRENT_USER(); SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = CONCAT(QUOTE(SUBSTRING_INDEX(CURRENT_USER(), '@', 1)), '@', QUOTE(SUBSTRING_INDEX(CURRENT_USER(), '@', -1))) AND PRIVILEGE_TYPE = 'CREATE USER';"
}
admin_socket() {
 local account probe identity privilege
 for account in root "$(id -un)"; do
  probe=$(auth_probe "$account" 2>/dev/null) || continue
  identity=${probe%%$'\n'*}; privilege=${probe##*$'\n'}
  # SELECT 1 também funciona para contas anônimas: validar identidade real.
  [[ ${identity%@*} == "$account" && $identity == *@* && $privilege =~ ^[1-9][0-9]*$ ]] || continue
  mariadb --no-defaults --protocol=socket --socket="$RUN/mysql.sock" -u "$account" "$@"
  return $?
 done
 fail 'Nenhuma conta administrativa válida via socket. Execute tamp db-auth para diagnóstico; não é necessário apagar o banco.'
}
db_auth() {
 require_install
 local account probe identity privilege
 for account in root "$(id -un)"; do
  if probe=$(auth_probe "$account" 2>/dev/null); then
   identity=${probe%%$'\n'*}; privilege=${probe##*$'\n'}
   msg INFO "Solicitado: $account | Autenticado: $identity | CREATE USER global: $privilege"
  else
   msg AVISO "Solicitado: $account | Conexão ou consulta de privilégios recusada."
  fi
 done
}
recovery_files() {
 local dir=$1 hash quoted
 # Hash mysql_native_password; SQL de inicialização não contém a senha literal.
 hash=$(printf '%s' "$PASSWORD" | openssl dgst -sha1 -binary | openssl dgst -sha1 -r)
 hash=${hash%% *}
 [[ $hash =~ ^[a-fA-F0-9]{40}$ ]] || { fail 'Não foi possível gerar o hash da senha.'; return 1; }
 printf "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING '*%s';\nGRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;\n" "${hash^^}" > "$dir/init.sql"
 quoted=${PASSWORD//\\/\\\\}; quoted=${quoted//\"/\\\"}
 printf '[client]\nuser=root\npassword="%s"\n' "$quoted" > "$dir/client.cnf"
 chmod 600 "$dir/init.sql" "$dir/client.cnf"
}
recovery_shutdown() {
 local pid=$1
 if kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || return 1
  for _ in {1..100}; do
   kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null || :; return 0; }
   sleep .2
  done
  return 1
 fi
 wait "$pid" 2>/dev/null || :
}
recover_root() (
 set -Eeuo pipefail
 require_install
 umask 077
 local PASSWORD work= backup= child= verified=0 identity
 read_password "$PASSWORD_SOURCE"
 [[ $PASSWORD != *$'\r'* ]] || { fail 'A senha não pode conter CR.'; exit 2; }
 lock
 stop_service mariadb || { fail 'Recuperação cancelada: banco não está comprovadamente parado.'; exit 1; }
 mkdir -p "$RUN" "$BACKUPS"
 backup=$(mktemp -d "$BACKUPS/before-root-recovery.XXXXXX")
 msg ETAPA "Backup do banco parado: $backup"
 cp -a "$DATA" "$backup/mysql" || { fail 'Backup falhou; nenhuma credencial foi alterada.'; exit 1; }
 work=$(mktemp -d "$RUN/.root-recovery.XXXXXX")
 cleanup_recovery() {
  local rc=$?
  if [[ -n $child ]]; then
   if ! recovery_shutdown "$child"; then
    msg ERRO "Processo temporário ainda ativo (PID $child). Banco normal não deve ser iniciado. Logs: $work/server.log" >&2
    rc=1
   else child=; fi
  fi
  rm -f -- "$work/init.sql" "$work/client.cnf"
  if [[ -z $child ]]; then rm -rf -- "$work"; fi
  exit "$rc"
 }
 trap cleanup_recovery EXIT
 trap 'exit 130' INT
 trap 'exit 143' TERM
 recovery_files "$work"
 unset PASSWORD
 msg ETAPA 'Recuperando root no banco existente, com TCP desativado temporariamente...'
 # O processo é filho direto desta operação; fd 9 não deve manter o lock vivo.
 setsid "$PREFIX/bin/mariadbd" --no-defaults --datadir="$DATA" \
  --socket="$work/db.sock" --pid-file="$work/db.pid" --skip-networking \
  --init-file="$work/init.sql" --log-error="$work/server.log" >"$work/console.log" 2>&1 9>&- &
 child=$!
 for _ in {1..150}; do
  if identity=$(mariadb --defaults-file="$work/client.cnf" --protocol=socket --socket="$work/db.sock" \
   --batch --skip-column-names --execute "SELECT CURRENT_USER(); SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE GRANTEE = '\\'root\\'@\\'localhost\\'' AND PRIVILEGE_TYPE = 'CREATE USER';" 2>/dev/null); then
   if [[ $identity == $'root@localhost\n1' ]]; then verified=1; break; fi
  fi
  kill -0 "$child" 2>/dev/null || break
  sleep .2
 done
 ((verified)) || { fail 'Recuperação não confirmada. Backup preservado; não foi iniciado o banco normal. Não apague o datadir.'; exit 1; }
 recovery_shutdown "$child" || { fail 'Servidor temporário não encerrou; operação interrompida.'; exit 1; }
 child=
 rm -f -- "$work/init.sql"
 flock -u 9
 service_action start mariadb
 # Verificar o mesmo transporte usado pelo phpMyAdmin, com a senha escolhida.
 identity=$(mariadb --defaults-file="$work/client.cnf" --protocol=tcp --host=127.0.0.1 --port=3306 \
  --batch --skip-column-names --execute 'SELECT CURRENT_USER();' 2>/dev/null) || {
   fail 'Root foi recuperado pelo socket, mas o teste TCP falhou. Execute tamp logs mariadb.'; exit 1;
  }
 [[ $identity == root@localhost ]] || { fail 'A identidade TCP não corresponde a root@localhost.'; exit 1; }
 msg OK "Root recuperado e login TCP confirmado. Backup anterior: $backup"
 msg INFO 'Use root e a nova senha no phpMyAdmin. Console: tamp sql --password'
)
configure_root() (
 set -Eeuo pipefail
 require_install
 local PASSWORD escaped
 read_password "$PASSWORD_SOURCE"
 escaped=${PASSWORD//\'/\'\'}
 # Manter unix_socket além da senha, para preservar administração local existente.
 if ! admin_socket >/dev/null 2>/dev/null <<SQL
SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$escaped');
SQL
 then
  unset PASSWORD escaped
  fail 'Não foi possível alterar root (autenticação, privilégios ou SQL). Saída SQL ocultada para proteger a senha. Execute tamp db-auth.'
  exit 1
 fi
 unset PASSWORD escaped
 msg OK 'Senha de root@localhost configurada. Entre no phpMyAdmin com root e essa senha.'
)
ssl() {
 require_install
 mkdir -p "$CONF/tls"; chmod 700 "$CONF/tls"
 if [[ ! -f $CONF/tls/server.key ]]; then
  (umask 077; openssl req -x509 -newkey rsa:3072 -nodes -days 365 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1' -keyout "$CONF/tls/server.key" -out "$CONF/tls/server.crt")
 fi
 TLS=on; configure
 msg INFO 'Certificado local autoassinado. Execute tamp restart para aplicar.'
}
stop_supervisor() {
 local proc pid
 local -a argv=()
 for proc in /proc/[0-9]*/cmdline; do
  argv=()
  [[ -r $proc ]] || continue
  mapfile -d '' -t argv < "$proc" 2>/dev/null || continue
  ((${#argv[@]} == 2)) || continue
  [[ ${argv[0]##*/} == runsvdir && ${argv[1]} == "$SERVICES" ]] || continue
  pid=${proc#/proc/}; pid=${pid%/cmdline}
  kill -TERM "$pid" 2>/dev/null || { [[ ! -e /proc/$pid ]] || return 1; }
  for _ in {1..50}; do
   [[ -e /proc/$pid ]] || break
   sleep .1
  done
  [[ ! -e /proc/$pid ]] || { fail 'Supervisor ainda ativo; remoção interrompida.'; return 1; }
 done
 return 0
}
uninstall() (
 set -Eeuo pipefail
 local name target="$PREFIX/etc/phpmyadmin/config.inc.php" failed=0
 local -a added=() managed=()
 [[ $PURGE_DATA == 0 ]] || msg AVISO "Serão apagados banco, logs, configurações e backups de $BASE. Projetos em $ROOT serão preservados."
 # Encerrar supervisores antes de remover seus scripts ou dados. Não apagar FIFOs.
 for name in apache mariadb; do
  [[ ! -d $SERVICES/$name ]] || managed+=("$name")
 done
 if ((${#managed[@]})); then
  lock
  supervise "${managed[@]}"
  for name in "${managed[@]}"; do
   stop_service "$name" || failed=1
  done
  ((failed == 0)) || { fail 'Não foi possível parar os serviços; remoção cancelada.'; exit 1; }
  # Remover diretórios da árvore observada impede que runsvdir recrie runsv.
  local retired
  retired=$(mktemp -d "$BASE/.retired.XXXXXX")
  for name in "${managed[@]}"; do
   mv "$SERVICES/$name" "$retired/$name"
   sv -w 20 shutdown "$retired/$name" || failed=1
  done
  ((failed == 0)) || { fail "Supervisor não encerrou. Dados preservados; veja $retired."; exit 1; }
  rm -rf -- "$retired"
 fi
 stop_supervisor
 if [[ -f $CONF/phpmyadmin.managed ]] && cmp -s "$target" "$CONF/phpmyadmin.managed"; then
  if [[ -f $CONF/phpmyadmin.original ]]; then cp -p "$CONF/phpmyadmin.original" "$target"
  elif [[ -f $CONF/phpmyadmin.was-absent ]]; then rm -f "$target"; fi
 elif [[ -f $CONF/phpmyadmin.managed ]]; then
  msg AVISO 'phpMyAdmin alterado fora do TAMP: arquivo atual preservado.'
 fi
 for name in tamp tamp-start tamp-stop tamp-restart tamp-status tamp-doctor tamp-logs; do
  if [[ -f $PREFIX/bin/$name ]] && rg_marker "$PREFIX/bin/$name"; then
   rm -f "$PREFIX/bin/$name"
   [[ ! -f $BACKUPS/legacy-commands/$name ]] || cp -p "$BACKUPS/legacy-commands/$name" "$PREFIX/bin/$name"
  fi
 done
 if [[ $REMOVE_PACKAGES == 1 ]]; then
  if [[ -f $BASE/packages-added ]]; then
   while IFS= read -r name; do
    case $name in apache2|php|php-apache|phpmyadmin|mariadb|openssl-tool|curl|termux-services|runit|util-linux)
     [[ $(dpkg-query -W -f='${Status}' "$name" 2>/dev/null || :) != 'install ok installed' ]] || added+=("$name");;
     *) fail 'Registro de pacotes inválido; remoção interrompida.'; exit 1;;
    esac
   done < "$BASE/packages-added"
   if ((${#added[@]})); then
    # apt pode propor remover dependentes: abortar se a transação incluir outro pacote.
    local simulation line candidate
    simulation=$(LC_ALL=C apt-get -s remove "${added[@]}")
    while IFS= read -r line; do
     [[ $line == 'Remv '* ]] || continue
     candidate=${line#Remv }; candidate=${candidate%% *}
     case " ${added[*]} " in *" $candidate "*) :;; *) fail "A remoção afetaria outro pacote ($candidate). Desinstale sem --remove-packages."; exit 1;; esac
    done <<< "$simulation"
    DEBIAN_FRONTEND=noninteractive apt-get -y remove "${added[@]}"
   fi
  else msg AVISO 'Instalação anterior sem registro de pacotes: pacotes preservados.'; fi
 fi
 rm -rf -- "$APP"
 rm -f "$CONF/httpd.conf" "$CONF/settings"
 if [[ $PURGE_DATA == 1 ]]; then
  [[ $BASE == "$PREFIX/var/lib/tamp" && $PREFIX != / && -n $PREFIX ]] || exit 1
  rm -rf -- "$BASE"
  msg OK 'TAMP e seus dados removidos. Projetos pessoais preservados.'
 else msg OK "Integração removida. Banco, backups e logs preservados em $BASE. Projetos: $ROOT"; fi
)
rg_marker() { grep -q '^# managed-by-tamp-1$' "$1"; }
usage() {
 cat <<'HELP'
TAMP — CLI sem menu interativo
Uso: tamp COMANDO [OPÇÕES]   ou   bash install.sh --COMANDO [OPÇÕES]

  install [--replace-existing]       Instalar/reparar; manter dados existentes
  start|stop|restart [apache|mariadb|all]
  status|doctor|logs [apache|mariadb|all]
                                    Também aceita --service NOME; padrão: all
  db-auth                           Diagnosticar contas e privilégio administrativo
  root --recover --password-file ARQUIVO  Recuperar root existente (backup + reinício)
  root --password-file ARQUIVO
  root --password-stdin
                                    Senha na primeira linha, mínimo 12 caracteres
  sql [--password] [--execute SQL]                Console SQL explícito ou consulta sem interação
  storage private|shared            Diretório privado ou compartilhado/Acode
  profile local|lan                 Endereço de escuta HTTP
  ssl on|off                        Ativar/desativar HTTPS local
  diagnose /caminho/                Consultar HTTP e mostrar logs Apache/PHP
  configure                         Reaplicar configuração atual
  uninstall --yes                   Desfazer integração; preservar dados e projetos
    [--purge-data]                  Apagar banco, logs, configurações e backups TAMP
    [--remove-packages]             Remover apenas pacotes registrados como adicionados
  --help, -h                        Mostrar ajuda e sair
  --version                         Mostrar versão

Sem argumentos: mostra esta ajuda. Não abre menu nem solicita confirmações.
Não use senha em argumentos. Projetos e dependências indiretas não são apagados.
Exemplos:
  tamp --start --service mariadb
  tamp doctor mariadb
  tamp sql --execute 'SELECT VERSION();'
  tamp uninstall --yes --purge-data --remove-packages
HELP
}
cli_error() { fail "$*. Use tamp --help." || :; return 2; }
main() {
 local action=${1:-help} target=all value= query= execute_sql=0
 REPLACE_EXISTING=0; PURGE_DATA=0; REMOVE_PACKAGES=0
 PASSWORD_SOURCE=; SQL_PASSWORD=0; RECOVER_ROOT=0
 (($# == 0)) || shift
 case $action in
  -h|--help|help) (($# == 0)) || { cli_error 'Argumentos extras'; return 2; }; usage; return;;
  --version|version) (($# == 0)) || { cli_error 'Argumentos extras'; return 2; }; printf '%s\n' "$VERSION"; return;;
 esac
 action=${action#--}
 case $action in
  start|stop|restart|status|doctor|logs)
   if [[ ${1:-} == --service ]]; then
    shift
    (($# == 1)) || { cli_error 'Falta valor para --service'; return 2; }
   fi
   (($# <= 1)) || { cli_error 'Use apenas um seletor de serviços'; return 2; }
   target=${1:-all}; select_services "$target" || return 2;;
  install)
   if [[ ${1:-} == --replace-existing ]]; then REPLACE_EXISTING=1; shift; fi
   (($# == 0)) || { cli_error 'Opção de instalação inválida'; return 2; };;
  uninstall)
   local yes=0
   while (($#)); do
    case $1 in --yes) yes=1;; --purge-data) PURGE_DATA=1;; --remove-packages) REMOVE_PACKAGES=1;; *) cli_error "Opção inválida: $1"; return 2;; esac
    shift
   done
   ((yes)) || { cli_error 'Desinstalação exige --yes'; return 2; };;
  storage|profile|ssl)
   (($# == 1)) || { cli_error 'Informe exatamente um valor'; return 2; }
   value=$1
   case "$action:$value" in storage:private|storage:shared|profile:local|profile:lan|ssl:on|ssl:off) :;; *) cli_error 'Valor inválido'; return 2;; esac;;
  root)
   if [[ ${1:-} == --recover ]]; then RECOVER_ROOT=1; shift; fi
   case ${1:-} in
    --password-file) [[ $# == 2 && -n $2 && $2 != - && $2 != --* ]] || { cli_error 'Informe um arquivo de senha'; return 2; }; PASSWORD_SOURCE=$2;;
    --password-stdin) [[ $# == 1 ]] || { cli_error 'Argumentos extras'; return 2; }; PASSWORD_SOURCE=-;;
    *) cli_error 'Use root --password-file ARQUIVO ou --password-stdin'; return 2;;
   esac;;
  sql)
   while (($#)); do
    case $1 in
     --password) SQL_PASSWORD=1; shift;;
     --execute) [[ $# -ge 2 && -n $2 ]] || { cli_error 'Informe SQL'; return 2; }; query=$2; execute_sql=1; shift 2;;
     *) cli_error 'Use sql [--password] [--execute SQL]'; return 2;;
    esac
   done;;
  diagnose)
   [[ $# == 1 && $1 == /* && $1 != //* && $1 != *$'\n'* && $1 != *$'\r'* ]] || { cli_error 'Informe um caminho local, como /projeto/'; return 2; }
   value=$1;;
  configure|db-auth) (($# == 0)) || { cli_error 'Argumentos extras'; return 2; };;
  *) cli_error "Comando desconhecido: $action"; return 2;;
 esac
 init
 trap 'msg ERRO "Operação interrompida." >&2; exit 130' INT
 case $action in
  install) install;; uninstall) uninstall;;
  start|stop|restart) service_action "$action" "$target";;
  status|doctor|logs) "$action" "$target";;
  root) if ((RECOVER_ROOT)); then recover_root; else configure_root; fi;;
  db-auth) db_auth;;
  diagnose) diagnose_http "$value";;
  sql) if ((execute_sql)); then
   require_install
   if ((SQL_PASSWORD)); then mariadb --no-defaults --socket="$RUN/mysql.sock" -u root -p --execute "$query"
   else admin_socket --execute "$query"; fi
  else sql_console; fi;;
  configure) require_install; configure;;
  storage)
   require_install
   if [[ $value == shared ]]; then
    [[ -d $HOME/storage/shared && -w $HOME/storage/shared ]] || { fail 'Execute termux-setup-storage, conceda a permissão Android e repita storage shared.'; return 1; }
    ROOT="$HOME/storage/shared/htdocs"
   else ROOT="$HOME/htdocs"; fi
   configure; msg INFO 'Projetos não foram movidos. Aplique com tamp restart apache.';;
  profile) require_install; PROFILE=$value; configure; msg INFO 'Aplique com tamp restart apache.';;
  ssl) if [[ $value == on ]]; then ssl; else require_install; TLS=off; configure; msg INFO 'Aplique com tamp restart apache.'; fi;;
 esac
}
