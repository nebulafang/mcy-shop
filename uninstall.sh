#!/usr/bin/env bash
# 删除 deploy.sh 创建的商城实例及其数据；不卸载共享系统软件。
set -Eeuo pipefail
umask 077

STATE_FILE=/etc/mcy-shop/deploy.json
SOURCE_FILE=/etc/mcy-shop/source-dir
CREDENTIALS_FILE=/root/mcy-shop-credentials.txt
SITE_FILE=/etc/nginx/sites-available/mcy-shop.conf
ENABLED_FILE=/etc/nginx/sites-enabled/mcy-shop.conf
POOL_FILE=/etc/php/8.4/fpm/pool.d/mcy-shop.conf
HOOK_FILE=/etc/letsencrypt/renewal-hooks/deploy/mcy-shop-nginx
ACME_DIR=/var/lib/mcy-shop
WORK_DIR=
APP_DIR=
DOMAIN=
HAS_DATABASE=0
REMOVE_USER=0
KEEP_CERTIFICATE=0
ASSUME_YES=0
DRY_RUN=0

log() { printf '\n[卸载] %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }
require_root() { [[ $EUID -eq 0 ]] || die '请使用 sudo bash uninstall.sh 运行。'; }
cleanup() { if [[ -n $WORK_DIR ]]; then rm -rf -- "$WORK_DIR"; fi; }

read_metadata() {
    local php_bin metadata
    php_bin=$(command -v php8.4 || command -v php) || die '缺少 PHP CLI，无法安全读取部署记录。'
    metadata=$("$php_bin" /dev/stdin "$STATE_FILE" "$SOURCE_FILE" <<'PHP'
<?php
try {
    if (is_file($argv[1])) {
        $s = json_decode(file_get_contents($argv[1]), true, 512, JSON_THROW_ON_ERROR);
        if (($s['db_name'] ?? '') !== 'mcy_shop' || ($s['db_user'] ?? '') !== 'mcy_shop') {
            throw new RuntimeException('数据库标识与部署脚本不匹配');
        }
        $dir = $s['app_dir'] ?? '';
        $domain = $s['domain'] ?? '';
        $hasDatabase = 1;
    } elseif (is_file($argv[2])) {
        $dir = trim(file_get_contents($argv[2]));
        $domain = 'shop.584136.xyz';
        $hasDatabase = 0;
        if (file_exists($dir . '/config/database.php') || file_exists($dir . '/kernel/Install/Lock')) {
            throw new RuntimeException('商城已初始化但部署记录缺失，拒绝猜测数据库归属');
        }
    } else {
        echo "absent\n";
        exit;
    }
    if (!preg_match('#^/var/www/[a-zA-Z0-9_-]+$#D', $dir) || is_link($dir)) {
        throw new RuntimeException('部署目录不合法或是符号链接');
    }
    if (!is_string($domain) || strlen($domain) > 253 || !preg_match('/^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63}$/D', $domain)) {
        throw new RuntimeException('部署域名不合法');
    }
    echo "$domain\n$dir\n$hasDatabase\n";
} catch (Throwable $e) {
    fwrite(STDERR, "读取部署记录失败：" . $e->getMessage() . "\n");
    exit(1);
}
PHP
    ) || die '部署记录检查失败，未执行卸载。'
    if [[ $metadata == absent ]]; then
        log '未找到本脚本管理的部署记录，无需卸载。'
        return 1
    fi
    local values
    mapfile -t values <<< "$metadata"
    DOMAIN=${values[0]}
    APP_DIR=${values[1]}
    HAS_DATABASE=${values[2]}
}

check_ownership() {
    local file target account uid home shell mount mounts
    for file in "$SITE_FILE" "$POOL_FILE"; do
        if [[ -e $file || -L $file ]]; then
            if [[ ! -f $file || -L $file ]] || ! head -n 1 "$file" | grep -q 'Managed by mcy-shop deploy.sh'; then
                die "配置不属于部署脚本，未删除：$file"
            fi
        fi
    done
    if [[ -e $ENABLED_FILE || -L $ENABLED_FILE ]]; then
        [[ -L $ENABLED_FILE && $(readlink "$ENABLED_FILE") == "$SITE_FILE" ]] || die "站点入口不属于部署脚本：$ENABLED_FILE"
    fi
    mounts=$(findmnt -rn -o TARGET) || die '无法读取挂载点，未执行卸载。'
    for target in "$APP_DIR" "$ACME_DIR"; do
        [[ ! -L $target ]] || die "拒绝删除符号链接目录：$target"
        [[ $(realpath -m -- "$target") == "$target" ]] || die "目录父级包含符号链接：$target"
        while IFS= read -r mount; do
            [[ $mount != "$target" && $mount != "$target/"* ]] || die "目录包含挂载点，请先卸载挂载：$mount"
        done <<< "$mounts"
    done
    if account=$(getent passwd mcy-shop); then
        IFS=: read -r _ _ uid _ _ home shell <<< "$account"
        [[ $uid != 0 && $home == "$APP_DIR" && $shell == /usr/sbin/nologin ]] || die 'mcy-shop 系统用户与部署记录不匹配，拒绝删除。'
        REMOVE_USER=1
        command -v pkill >/dev/null || die '需要 procps（pkill）来停止商城进程。'
    fi
    if [[ $KEEP_CERTIFICATE == 0 ]] && [[ -e /etc/letsencrypt/renewal/$DOMAIN.conf || -d /etc/letsencrypt/live/$DOMAIN ]]; then
        command -v certbot >/dev/null || die '缺少 certbot；恢复 certbot 或使用 --keep-certificate。'
        local dirs=() references
        for target in /etc/nginx /etc/apache2 /etc/haproxy /etc/caddy; do
            [[ ! -d $target ]] || dirs+=("$target")
        done
        if [[ ${#dirs[@]} -gt 0 ]]; then
            references=$(grep -R -l -F "/etc/letsencrypt/live/$DOMAIN/" "${dirs[@]}" 2>/dev/null || true)
            while IFS= read -r file; do
                [[ -z $file || $file == "$SITE_FILE" || $file == "$ENABLED_FILE" ]] || die "证书还被 $file 引用；请使用 --keep-certificate 保留共享证书。"
            done <<< "$references"
        fi
    fi
}

show_plan() {
    printf '\n即将永久删除：\n  商城域名：%s\n  程序、上传、插件：%s\n' "$DOMAIN" "$APP_DIR"
    if [[ $HAS_DATABASE == 1 ]]; then printf '  数据库：mcy_shop；数据库用户：mcy_shop@localhost\n'; fi
    printf '  Nginx 站点、PHP-FPM 池、商城系统用户、商城日志、ACME 文件\n  部署记录及初始密码文件\n'
    if [[ $KEEP_CERTIFICATE == 0 && $HAS_DATABASE == 1 ]]; then
        printf '  本域名的 Certbot 证书及续期配置（若存在）\n'
    else
        printf '  保留证书\n'
    fi
    printf '\n共享的 Nginx、PHP、MariaDB、Certbot 软件包、其他站点和数据库会保留。\n'
}

remove_web_configs() {
    # 先备份待删除的配置，检查共享服务后再重载；失败则恢复。
    local site=0 pool=0 enabled=0
    [[ ! -f $SITE_FILE ]] || { cp -p "$SITE_FILE" "$WORK_DIR/site.conf"; site=1; }
    [[ ! -f $POOL_FILE ]] || { cp -p "$POOL_FILE" "$WORK_DIR/pool.conf"; pool=1; }
    [[ ! -L $ENABLED_FILE ]] || enabled=1
    rm -f -- "$ENABLED_FILE" "$SITE_FILE" "$POOL_FILE"
    if { command -v nginx >/dev/null && ! nginx -t; } || { command -v php-fpm8.4 >/dev/null && ! php-fpm8.4 -t; }; then
        [[ $site == 0 ]] || cp -p "$WORK_DIR/site.conf" "$SITE_FILE"
        [[ $pool == 0 ]] || cp -p "$WORK_DIR/pool.conf" "$POOL_FILE"
        [[ $enabled == 0 ]] || ln -s "$SITE_FILE" "$ENABLED_FILE"
        die '共享服务配置检查失败，已恢复商城配置；尚未删除数据库或商城文件。'
    fi
    if systemctl is-active --quiet nginx; then systemctl reload nginx; fi
    if systemctl is-active --quiet php8.4-fpm; then systemctl reload php8.4-fpm; fi
    if [[ $REMOVE_USER == 1 ]]; then
        local status=0
        pkill -KILL -u mcy-shop || status=$?
        [[ $status == 0 || $status == 1 ]] || die '商城进程未能停止，保留数据供重试。'
    fi
}

remove_database() {
    [[ $HAS_DATABASE == 1 ]] || return 0
    mariadb --protocol=socket --user=root <<'SQL'
DROP DATABASE IF EXISTS `mcy_shop`;
DROP USER IF EXISTS 'mcy_shop'@'localhost';
SQL
}

remove_files() {
    if [[ $KEEP_CERTIFICATE == 0 && $HAS_DATABASE == 1 ]] && [[ -e /etc/letsencrypt/renewal/$DOMAIN.conf || -d /etc/letsencrypt/live/$DOMAIN ]]; then
        certbot delete --cert-name "$DOMAIN" --non-interactive
    fi
    # 路径来自已验证的部署记录，且拒绝挂载点；不会进入其他文件系统。
    rm -rf --one-file-system -- "$APP_DIR" "$ACME_DIR"
    rm -f -- "$HOOK_FILE" /run/php/mcy-shop.sock
    if [[ -d /var/log/nginx ]]; then
        find /var/log/nginx -maxdepth 1 -type f \( -name 'mcy-shop.access.log*' -o -name 'mcy-shop.error.log*' \) -delete
    fi
    if [[ $REMOVE_USER == 1 ]]; then
        userdel mcy-shop
        if getent group mcy-shop >/dev/null; then groupdel mcy-shop; fi
    fi
    # 最后删除记录，中途失败仍能使用同一脚本重试。
    rm -f -- "$CREDENTIALS_FILE" "$STATE_FILE" "$STATE_FILE.tmp" "$SOURCE_FILE"
    rmdir /etc/mcy-shop 2>/dev/null || true
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --yes) ASSUME_YES=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --keep-certificate) KEEP_CERTIFICATE=1 ;;
            -h|--help)
                printf '%s\n' '用法：sudo bash uninstall.sh [--dry-run] [--yes] [--keep-certificate]' \
                    '永久删除 deploy.sh 部署的商城、数据库和相关配置；保留共享系统软件。' \
                    '默认要求输入域名确认；--yes 跳过确认；--dry-run 只展示清单。'
                return ;;
            *) die "未知参数：$1" ;;
        esac
        shift
    done
    require_root
    command -v flock >/dev/null || die '缺少 flock，请先安装 util-linux。'
    command -v findmnt >/dev/null || die '缺少 findmnt，请先安装 util-linux。'
    exec 9>/run/lock/mcy-shop-deploy.lock
    flock -n 9 || die '部署或卸载脚本正在运行。'
    if ! read_metadata; then return; fi
    # 没有数据库记录的部署只清理源码，不能证明证书归属。
    if [[ $HAS_DATABASE == 0 ]]; then KEEP_CERTIFICATE=1; fi
    check_ownership
    show_plan
    if [[ $DRY_RUN == 1 ]]; then log '预览结束，未修改任何商城数据或服务。'; return; fi
    if [[ $ASSUME_YES == 0 ]]; then
        local answer
        printf '\n此操作不自动备份，且无法撤销。输入域名 %s 确认删除：' "$DOMAIN"
        read -r answer || die '未收到确认，已取消。'
        [[ $answer == "$DOMAIN" ]] || die '域名不匹配，已取消。'
    fi
    if [[ $HAS_DATABASE == 1 ]]; then
        command -v mariadb >/dev/null || die '缺少 mariadb 客户端，无法删除数据库。'
        mariadb --protocol=socket --user=root --batch --execute='SELECT 1' >/dev/null
    fi
    WORK_DIR=$(mktemp -d /tmp/mcy-shop-uninstall.XXXXXXXX)
    trap cleanup EXIT
    trap 'printf "\n[错误] 第 %s 行执行失败；保留的部署记录可用于重试。\n" "$LINENO" >&2' ERR
    log '停止商城并删除专属配置'
    remove_web_configs
    log '删除商城数据库、程序和凭据'
    remove_database
    remove_files
    log '商城已卸载。共享软件包已保留；DNS 记录及你自行保存的源码、备份需自行清理。'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
