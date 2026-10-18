#!/usr/bin/env bash
# Debian 13 原生部署；可放在项目目录中运行，也可单独下载运行。
set -Eeuo pipefail
umask 027

DOMAIN=${DOMAIN:-shop.584136.xyz}
APP_DIR=${APP_DIR:-/var/www/mcy-shop}
REPO_URL=${REPO_URL:-https://github.com/nebulafang/mcy-shop.git}
REPO_REF=${REPO_REF:-main}
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@${DOMAIN}}
LE_EMAIL=${LE_EMAIL:-}
ENABLE_HTTPS=${ENABLE_HTTPS:-1}
STATE_FILE=/etc/mcy-shop/deploy.json
SOURCE_FILE=/etc/mcy-shop/source-dir
CREDENTIALS_FILE=/root/mcy-shop-credentials.txt
SITE_FILE=/etc/nginx/sites-available/mcy-shop.conf
POOL_FILE=/etc/php/8.4/fpm/pool.d/mcy-shop.conf
ACME_ROOT=/var/lib/mcy-shop/acme
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=

log() { printf '\n[部署] %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }

preflight() {
    [[ $EUID -eq 0 ]] || die '请使用 root 运行：sudo bash deploy.sh'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ $ID == debian && $VERSION_ID == 13 ]] || die '本脚本仅支持 Debian 13。'
    [[ -d /run/systemd/system ]] || die '需要使用 systemd 的 VPS。'
    [[ $DOMAIN =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$ && ${#DOMAIN} -le 253 ]] || die 'DOMAIN 必须是小写域名。'
    [[ $APP_DIR =~ ^/var/www/[a-zA-Z0-9_-]+$ ]] || die 'APP_DIR 必须是 /var/www/ 下的一级目录，不能含空格。'
    [[ ! -L $APP_DIR ]] || die '应用目录不能是符号链接。'
    [[ $ENABLE_HTTPS == 0 || $ENABLE_HTTPS == 1 ]] || die 'ENABLE_HTTPS 只能是 0 或 1。'
    [[ $ADMIN_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ && ${#ADMIN_EMAIL} -le 64 ]] || die 'ADMIN_EMAIL 格式错误或超过 64 字符。'
    [[ -z $LE_EMAIL || $LE_EMAIL =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || die 'LE_EMAIL 格式错误。'
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    exec 9>/run/lock/mcy-shop-deploy.lock
    flock -n 9 || die '已有部署脚本正在运行。'
    for file in "$SITE_FILE" "$POOL_FILE"; do
        if [[ -e $file || -L $file ]]; then
            if [[ ! -f $file || -L $file ]] || ! head -n 1 "$file" | grep -q 'Managed by mcy-shop deploy.sh'; then
                die "配置已存在且不属于本脚本：$file"
            fi
        fi
    done
    local enabled=/etc/nginx/sites-enabled/mcy-shop.conf
    if [[ -e $enabled || -L $enabled ]]; then
        [[ -L $enabled && $(readlink "$enabled") == "$SITE_FILE" ]] || die "站点入口已存在且不属于本脚本：$enabled"
    fi
    if [[ ! -f $STATE_FILE && -d $APP_DIR ]] && [[ -n $(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] \
        && { [[ ! -f $SOURCE_FILE ]] || [[ $(cat "$SOURCE_FILE") != "$APP_DIR" ]]; }; then
        die "目标目录非空且没有部署记录：$APP_DIR。请保留现有数据，选择新的 APP_DIR。"
    fi
}

install_packages() {
    log '安装 Nginx、PHP 8.4、MariaDB、Certbot 和所需扩展'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl git tar openssl nginx mariadb-server \
        php8.4-cli php8.4-fpm php8.4-mysql php8.4-gd php8.4-curl php8.4-zip \
        php8.4-bcmath php8.4-mbstring php8.4-xml php8.4-opcache certbot
    systemctl enable --now mariadb
    # shellcheck disable=SC2016
    php8.4 -r 'foreach (["pdo_mysql", "gd", "curl", "zip", "bcmath", "mbstring", "xml", "openssl"] as $e) { if (!extension_loaded($e)) { fwrite(STDERR, "缺少 PHP 扩展：$e\n"); exit(1); } }'
}

# 只加载自动加载器，不加载 kernel/Kernel.php，以免 CLI 模式启动 Swoole。
# 数据库导入沿用项目的 SQL 模板和密码算法；已有表绝不重新导入。
database_setup() {
    export DOMAIN APP_DIR ADMIN_EMAIL STATE_FILE CREDENTIALS_FILE
    php8.4 /dev/stdin <<'PHP'
<?php
declare(strict_types=1);
error_reporting(E_ALL & ~E_DEPRECATED);
$root = getenv('APP_DIR');
$stateFile = getenv('STATE_FILE');
function saveState(array $state): void {
    $file = getenv('STATE_FILE');
    $tmp = $file . '.tmp';
    if (file_put_contents($tmp, json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n") === false) {
        throw new RuntimeException('无法保存部署状态');
    }
    chmod($tmp, 0600);
    if (!rename($tmp, $file)) { throw new RuntimeException('无法提交部署状态'); }
}
try {
    $pdo = new PDO('mysql:unix_socket=/run/mysqld/mysqld.sock;charset=utf8mb4', 'root', '', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    if (is_file($stateFile)) {
        $s = json_decode(file_get_contents($stateFile), true, 512, JSON_THROW_ON_ERROR);
        if ($s['domain'] !== getenv('DOMAIN') || $s['app_dir'] !== $root) {
            throw new RuntimeException('部署记录的域名或目录与本次参数不同；请使用首次部署时的参数');
        }
    } else {
        if (is_file($root . '/kernel/Install/Lock') || is_file($root . '/config/database.php')) {
            throw new RuntimeException('检测到已有商城配置，拒绝覆盖');
        }
        if ($pdo->query("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='mcy_shop'")->fetchColumn()
            || $pdo->query("SELECT User FROM mysql.user WHERE User='mcy_shop'")->fetchColumn()) {
            throw new RuntimeException('数据库或用户 mcy_shop 已存在，拒绝接管');
        }
        $s = ['domain' => getenv('DOMAIN'), 'app_dir' => $root, 'db_name' => 'mcy_shop',
            'db_user' => 'mcy_shop', 'db_password' => bin2hex(random_bytes(24)),
            'admin_email' => getenv('ADMIN_EMAIL'), 'admin_password' => 'Mc9_' . bin2hex(random_bytes(10)),
            'schema_started' => false, 'schema_done' => false];
        saveState($s);
    }
    $db = $s['db_name'];
    $user = $s['db_user'];
    if ($db !== 'mcy_shop' || $user !== 'mcy_shop') { throw new RuntimeException('部署记录中的数据库标识无效'); }
    if ($s['schema_started'] && !$s['schema_done']) {
        throw new RuntimeException('上次数据库导入中断。为防止误删，已停止；请先备份并人工检查数据库，勿直接删除部署记录重装');
    }
    if (!$s['schema_done']) {
        $pdo->exec("CREATE DATABASE IF NOT EXISTS `$db` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
        $pdo->exec("CREATE USER IF NOT EXISTS '$user'@'localhost' IDENTIFIED BY " . $pdo->quote($s['db_password']));
        $pdo->exec("GRANT ALL PRIVILEGES ON `$db`.* TO '$user'@'localhost'");
    }
    $appDb = new PDO("mysql:host=localhost;dbname=$db;charset=utf8mb4", $user, $s['db_password'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    if (!$s['schema_done']) {
        if ($appDb->query('SHOW TABLES')->fetchColumn()) { throw new RuntimeException('数据库非空，拒绝运行包含 DROP TABLE 的安装 SQL'); }
        require $root . '/vendor/autoload.php';
        $salt = bin2hex(random_bytes(16));
        $hash = Kernel\Util\Str::generatePassword($s['admin_password'], $salt);
        $sql = file_get_contents($root . '/kernel/Install/Install.sql');
        if (!$sql) { throw new RuntimeException('缺少安装 SQL'); }
        $replace = ['${prefix}' => 'acg_'];
        foreach (['email' => $s['admin_email'], 'password' => $hash, 'nickname' => '管理员', 'salt' => $salt] as $key => $value) {
            $replace['\'' . '${' . $key . '}' . '\''] = $appDb->quote($value);
        }
        $s['schema_started'] = true;
        saveState($s);
        $appDb->exec(strtr($sql, $replace));
        $s['schema_done'] = true;
        saveState($s);
    }
    if (!$appDb->query('SELECT id FROM acg_manage WHERE id=1')->fetchColumn()) { throw new RuntimeException('管理员记录不存在'); }
    if (empty($s['site_bound'])) {
        $site = json_decode($appDb->query("SELECT value FROM acg_config WHERE `key`='site' AND user_id IS NULL")->fetchColumn(), true, 512, JSON_THROW_ON_ERROR);
        $domains = array_filter(explode("\n", (string)($site['domains'] ?? '')));
        if (!in_array($s['domain'], $domains, true)) { $domains[] = $s['domain']; }
        $site['domains'] = implode("\n", $domains);
        $stmt = $appDb->prepare("UPDATE acg_config SET value=? WHERE `key`='site' AND user_id IS NULL");
        $stmt->execute([json_encode($site, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)]);
        $s['site_bound'] = true;
        saveState($s);
    }
    $configFile = $root . '/config/database.php';
    if (!is_file($configFile)) {
        $config = ['driver' => 'mysql', 'host' => 'localhost', 'database' => $db,
            'username' => $user, 'password' => $s['db_password'], 'charset' => 'utf8mb4',
            'collation' => 'utf8mb4_unicode_ci', 'prefix' => 'acg_', 'pool' => 10];
        if (file_put_contents($configFile, "<?php\ndeclare(strict_types=1);\nreturn " . var_export($config, true) . ";\n") === false) {
            throw new RuntimeException('写入数据库配置失败');
        }
    }
    $lock = $root . '/kernel/Install/Lock';
    if (!is_file($lock) && file_put_contents($lock, bin2hex(random_bytes(16))) === false) { throw new RuntimeException('写入安装锁失败'); }
    $credentials = "域名：{$s['domain']}\n后台：https://{$s['domain']}/admin\n管理员邮箱：{$s['admin_email']}\n初始管理员密码：{$s['admin_password']}\n"
        . "数据库地址：localhost\n数据库名称：$db\n数据库用户：$user\n数据库密码：{$s['db_password']}\n表前缀：acg_\n"
        . "注意：这里保存的是首次部署密码；在后台改密后请使用新密码。HTTP 模式请改用 http://。\n";
    if (file_put_contents(getenv('CREDENTIALS_FILE'), $credentials) === false) { throw new RuntimeException('保存凭据失败'); }
    chmod(getenv('CREDENTIALS_FILE'), 0600);
    echo "数据库及管理员已就绪；已有安装不会重新导入。\n";
} catch (Throwable $e) {
    fwrite(STDERR, "初始化失败：" . $e->getMessage() . "\n");
    exit(1);
}
PHP
}

prepare_source() {
    log '准备商城文件'
    install -d -m 0700 /etc/mcy-shop
    if [[ -f $STATE_FILE && -f $APP_DIR/index.php ]]; then
        log '保留当前代码、配置和上传文件（本脚本不执行升级）'
        return
    fi
    local source_dir=$SCRIPT_DIR
    if [[ ! -f $source_dir/index.php || ! -f $source_dir/composer.json ]]; then
        git clone --depth 1 --branch "$REPO_REF" -- "$REPO_URL" "$WORK_DIR/source"
        source_dir=$WORK_DIR/source
    fi
    [[ ! -e $source_dir/kernel/Install/Lock && ! -e $source_dir/config/database.php ]] || die '源目录已安装，不能作为全新部署源。'
    install -d -m 0755 "$APP_DIR"
    printf '%s\n' "$APP_DIR" > "$SOURCE_FILE"
    chmod 0600 "$SOURCE_FILE"
    tar -C "$source_dir" --exclude='./.git' --exclude='./runtime' --exclude='./deploy.sh' --exclude='./DEPLOY.md' -cf - . | tar -C "$APP_DIR" -xf -
    if [[ ! -f $APP_DIR/vendor/autoload.php ]]; then
        [[ -f $APP_DIR/composer.phar ]] || die '源码缺少 vendor 和 composer.phar。'
        (cd "$APP_DIR" && COMPOSER_ALLOW_SUPERUSER=1 php8.4 composer.phar install --no-dev --prefer-dist --no-interaction --no-scripts --no-plugins)
    fi
    (cd "$APP_DIR" && php8.4 composer.phar check-platform-reqs --no-dev)
}

configure_php() {
    log '配置独立 PHP-FPM 进程池'
    if ! id mcy-shop >/dev/null 2>&1; then
        useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin mcy-shop
    fi
    install -d -m 0750 -o mcy-shop -g mcy-shop "$APP_DIR/runtime" "$APP_DIR/usr"
    # 插件、模板及在线更新需要应用目录写权限；仅数据库配置使用 0640。
    chown -R mcy-shop:mcy-shop "$APP_DIR"
    find "$APP_DIR" -type d -exec chmod 0755 {} +
    find "$APP_DIR" -type f -exec chmod u+rw,go+r,go-w {} +
    chmod 0700 "$APP_DIR/runtime"
    chmod 0640 "$APP_DIR/config/database.php"
    cat > "$POOL_FILE" <<EOF
; Managed by mcy-shop deploy.sh
[mcy-shop]
user = mcy-shop
group = mcy-shop
listen = /run/php/mcy-shop.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 20s
pm.max_requests = 500
chdir = $APP_DIR
catch_workers_output = yes
security.limit_extensions = .php
php_admin_flag[display_errors] = off
php_admin_flag[log_errors] = on
php_admin_value[date.timezone] = Asia/Shanghai
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 32M
php_admin_value[post_max_size] = 40M
php_admin_value[max_execution_time] = 300
php_admin_value[cgi.fix_pathinfo] = 0
EOF
    /usr/sbin/php-fpm8.4 -t
    systemctl enable --now php8.4-fpm
    systemctl reload php8.4-fpm
}

render_nginx() {
    local tls=$1
    cat <<EOF
# Managed by mcy-shop deploy.sh
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ {
        root $ACME_ROOT;
        default_type text/plain;
        try_files \$uri =404;
    }
EOF
    if [[ $tls == 1 ]]; then
        cat <<EOF
    location / { return 301 https://$DOMAIN\$request_uri; }
}
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
EOF
    fi
    cat <<EOF
    root $APP_DIR;
    index index.php;
    autoindex off;
    client_max_body_size 40m;
    access_log /var/log/nginx/mcy-shop.access.log;
    error_log /var/log/nginx/mcy-shop.error.log;
    add_header X-Content-Type-Options nosniff always;

    location ~ /\. { return 404; }
    location ~* ^/(config|kernel|runtime|vendor|deploy|tests)(/|$) { return 404; }
    location ~* ^/(bin|console\.sh|dev\.sh|deploy\.sh|composer\.(json|lock|phar)|README\.md|DEPLOY\.md|LICENSE)$ { return 404; }
    location ^~ /install { return 404; }

    # 只执行前端入口；上传目录及插件内 PHP 文件均不能直接执行。
    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root/index.php;
        fastcgi_param HTTP_PROXY "";
        fastcgi_param HTTP_X_FORWARDED_FOR \$remote_addr;
        fastcgi_param HTTP_X_REAL_IP \$remote_addr;
        fastcgi_pass unix:/run/php/mcy-shop.sock;
        fastcgi_read_timeout 300;
    }
    location ~* \.(php[0-9]*|phtml|phar)(/|$) { return 404; }
    # 插件/模板公开目录可提供静态文件，其他 app/usr 文件保持不可访问。
    location ~* ^/(assets/|(?:app|usr)/Plugin/.+/(?:Assets|assets)/).+\.(css|js|mjs|png|jpe?g|gif|webp|avif|svg|ico|woff2?|ttf|otf|eot|mp3|mp4|ogg|wav|webm|pdf|txt|json|map)$ {
        disable_symlinks on;
        try_files \$uri =404;
        expires 7d;
    }
    location ~* ^/(app|usr)(/|$) { return 404; }
    location = /favicon.ico { try_files \$uri =404; }
    location / { rewrite ^ /index.php?_route=\$uri last; }
}
EOF
}

configure_nginx() {
    local tls=$1 had_site=0 had_link=0
    [[ ! -e $SITE_FILE ]] || { cp -p "$SITE_FILE" "$WORK_DIR/nginx.previous"; had_site=1; }
    [[ ! -L /etc/nginx/sites-enabled/mcy-shop.conf ]] || had_link=1
    render_nginx "$tls" > "$WORK_DIR/nginx.conf"
    install -m 0644 "$WORK_DIR/nginx.conf" "$SITE_FILE"
    ln -sfn "$SITE_FILE" /etc/nginx/sites-enabled/mcy-shop.conf
    if ! nginx -t; then
        if [[ $had_site == 1 ]]; then cp -p "$WORK_DIR/nginx.previous" "$SITE_FILE"; else rm -f "$SITE_FILE"; fi
        if [[ $had_link == 0 ]]; then rm -f /etc/nginx/sites-enabled/mcy-shop.conf; fi
        die 'Nginx 配置检查失败，已恢复本次修改的站点配置。'
    fi
    systemctl enable --now nginx
    systemctl reload nginx
}

setup_https() {
    log "为 $DOMAIN 申请/检查 HTTPS 证书（需要 DNS 已解析且公网 80/443 端口放行）"
    local email_args=(--register-unsafely-without-email)
    [[ -z $LE_EMAIL ]] || email_args=(--email "$LE_EMAIL")
    if ! certbot certonly --webroot -w "$ACME_ROOT" -d "$DOMAIN" --cert-name "$DOMAIN" \
        --non-interactive --agree-tos --keep-until-expiring "${email_args[@]}"; then
        die '证书申请失败。商城数据已保留，请检查 DNS 的 A/AAAA 记录、云安全组、80/443 端口后重跑同一命令。详情：/var/log/letsencrypt/letsencrypt.log'
    fi
    install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/mcy-shop-nginx <<'EOF'
#!/bin/sh
/usr/sbin/nginx -t && /usr/bin/systemctl reload nginx
EOF
    chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/mcy-shop-nginx
    systemctl enable --now certbot.timer
    configure_nginx 1
}

health_check() {
    log '检查服务、后台页面和敏感路径访问限制'
    local scheme=http port=80 status body="$WORK_DIR/health.html"
    if [[ $ENABLE_HTTPS == 1 ]]; then scheme=https; port=443; fi
    systemctl is-active --quiet nginx php8.4-fpm mariadb
    # 连接本机仍校验证书和 SNI，避免 DNS/CDN 干扰本地健康检查。
    status=$(curl --noproxy '*' --silent --show-error --max-time 30 --resolve "$DOMAIN:$port:127.0.0.1" \
        -o "$body" -w '%{http_code}' "$scheme://$DOMAIN/admin")
    if [[ $status != 200 ]] || ! grep -q 'name="password"\|type="password"' "$body"; then
        die "后台健康检查未通过（HTTP $status），请查看 /var/log/nginx/mcy-shop.error.log 和 journalctl -u php8.4-fpm。"
    fi
    status=$(curl --noproxy '*' --silent --show-error --max-time 30 --resolve "$DOMAIN:$port:127.0.0.1" \
        -o "$body" -w '%{http_code}' "$scheme://$DOMAIN/")
    if [[ $status != 200 ]] || grep -q '服务器出现错误\|发生了致命错误\|当前域名未绑定' "$body"; then
        die "商城首页检查未通过（HTTP $status），请查看 $APP_DIR/runtime/error.log。"
    fi
    local path
    for path in /config/database.php /kernel/Install/Install.sql /vendor/composer/installed.json /deploy.sh /install /assets/test.php; do
        status=$(curl --noproxy '*' --silent --show-error --max-time 10 --resolve "$DOMAIN:$port:127.0.0.1" \
            -o /dev/null -w '%{http_code}' "$scheme://$DOMAIN$path")
        [[ $status == 404 ]] || die "敏感路径未拦截：$path（HTTP $status）"
    done
}

main() {
    [[ ${1:-} != --help && ${1:-} != -h ]] || {
        printf '%s\n' '用法：sudo bash deploy.sh' \
            '可选环境变量：DOMAIN APP_DIR REPO_URL REPO_REF ADMIN_EMAIL LE_EMAIL ENABLE_HTTPS=0' \
            '默认域名 shop.584136.xyz；默认开启 HTTPS；重复运行保留数据和初始密码，不升级代码。'
        return
    }
    [[ $# -eq 0 ]] || die '不支持该参数，请运行 bash deploy.sh --help。'
    preflight
    trap cleanup EXIT
    trap 'printf "\n[错误] 第 %s 行执行失败；请检查上方输出，修复后重跑。\n" "$LINENO" >&2' ERR
    WORK_DIR=$(mktemp -d /tmp/mcy-shop-deploy.XXXXXXXX)
    install_packages
    prepare_source
    database_setup
    configure_php
    install -d -m 0755 "$ACME_ROOT/.well-known/acme-challenge"
    local tls=0
    if [[ $ENABLE_HTTPS == 1 && -f /etc/letsencrypt/live/$DOMAIN/fullchain.pem && -f /etc/letsencrypt/live/$DOMAIN/privkey.pem ]]; then tls=1; fi
    configure_nginx "$tls"
    if [[ $ENABLE_HTTPS == 1 ]]; then setup_https; fi
    health_check
    local scheme=http
    [[ $ENABLE_HTTPS == 0 ]] || scheme=https
    log "部署完成：$scheme://$DOMAIN"
    printf '后台：%s://%s/admin\n账号和初始密码：%s（root 查看）\n查看命令：cat %s\n程序目录：%s\n' \
        "$scheme" "$DOMAIN" "$CREDENTIALS_FILE" "$CREDENTIALS_FILE" "$APP_DIR"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
