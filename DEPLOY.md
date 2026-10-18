# Debian 13 一键原生部署

适用于使用 systemd 的 Debian 13 VPS。脚本安装 Debian 官方源的 Nginx、PHP 8.4 FPM、MariaDB 和 Certbot，默认域名为 `shop.584136.xyz`，默认开启 HTTPS。支持 amd64/arm64，不使用项目自带的 `bin`，无需 Docker 或宝塔。

## 部署

先将 `shop.584136.xyz` 的 **A 记录**指向 VPS 公网 IPv4。有 AAAA 记录时，IPv6 也必须指向此 VPS 并可访问，否则删除不使用的 AAAA 记录。放行 VPS 防火墙、服务商安全组的 **TCP 80 和 443**；使用 CDN 时，首次申请证书建议暂时关闭代理。

将本项目上传到 VPS，例如 `/root/mcy-shop`，然后执行：

```bash
cd /root/mcy-shop
bash deploy.sh
```

普通用户执行 `sudo bash deploy.sh`。也可以只上传 `deploy.sh`，脚本会从 `https://github.com/nebulafang/mcy-shop.git` 的 `main` 分支获取源码；脚本放在完整项目旁边时优先使用本地源码（包含本地修改）。

完成后访问：

- 商城：<https://shop.584136.xyz>
- 后台：<https://shop.584136.xyz/admin>
- 默认管理员邮箱：`admin@shop.584136.xyz`

数据库和管理员均自动初始化，主站域名也会自动绑定，无需再运行网页安装向导。管理员密码随机生成，以 root 查看：

```bash
cat /root/mcy-shop-credentials.txt
```

该文件仅 root 可读，保存的是**初始密码**。首次登录后可在后台修改密码；再次执行脚本不会重置管理员密码。

## 可选设置

自定义管理员邮箱，并为 Let's Encrypt 注册联系邮箱：

```bash
sudo env ADMIN_EMAIL=you@example.com LE_EMAIL=you@example.com bash deploy.sh
```

省略 `LE_EMAIL` 时仍会申请证书，以无联系邮箱方式注册。脚本使用 Let's Encrypt，运行即同意其订阅协议。

暂时只部署 HTTP：

```bash
sudo env ENABLE_HTTPS=0 bash deploy.sh
```

DNS 就绪后再次执行 `sudo bash deploy.sh` 即可申请 HTTPS。HTTP 模式访问 `http://shop.584136.xyz`。

还支持 `DOMAIN`、`APP_DIR`（默认 `/var/www/mcy-shop`，仅允许 `/var/www/` 下一级目录）、`REPO_URL`、`REPO_REF`。脚本按单个商城实例设计；重复运行须使用首次部署的域名和目录。已有部署不会从仓库拉取升级，也不会重装 Composer 依赖。

## 数据与服务

| 内容 | 位置/名称 |
| --- | --- |
| 程序、上传、插件 | `/var/www/mcy-shop` |
| 数据库、数据库用户 | `mcy_shop`（仅 localhost） |
| 自动部署记录及初始密码 | `/etc/mcy-shop/deploy.json`（仅 root 可读） |
| 凭据摘要 | `/root/mcy-shop-credentials.txt`（仅 root 可读） |
| Nginx 站点 | `/etc/nginx/sites-available/mcy-shop.conf` |
| 独立 PHP-FPM 池 | `/etc/php/8.4/fpm/pool.d/mcy-shop.conf` |
| Nginx 日志 | `/var/log/nginx/mcy-shop.access.log`、`mcy-shop.error.log` |
| 证书自动续期 | `certbot.timer`，续期后自动重载 Nginx |

```bash
systemctl status nginx php8.4-fpm mariadb --no-pager
journalctl -u php8.4-fpm -n 80 --no-pager
tail -n 80 /var/log/nginx/mcy-shop.error.log
certbot renew --dry-run
```

FPM 模式适用于常规商城功能；依赖 Swoole 的 WebSocket、常驻后台进程类插件需要另外部署 CLI 服务。本脚本不自动开放 MariaDB 公网访问，不更改防火墙或其他 Nginx 站点，不授予应用用户 sudo 权限。商城内置的“自动配置分站 Nginx”需要另行配置，本脚本仅部署上述主域名。

## 彻底卸载商城

在保存源码的目录执行 `sudo bash uninstall.sh`。旧版源码没有该文件时，可以单独下载：

```bash
curl -fL https://raw.githubusercontent.com/nebulafang/mcy-shop/main/uninstall.sh -o /tmp/mcy-shop-uninstall.sh
sudo bash /tmp/mcy-shop-uninstall.sh
```

脚本读取实际部署记录，展示删除范围后要求输入域名确认。**执行会永久删除商城数据库、订单、账号、上传文件和插件，不会自动备份。**

```bash
# 只预览，不删除商城数据或修改服务
sudo bash uninstall.sh --dry-run

# 已确认删除范围，跳过交互确认
sudo bash uninstall.sh --yes

# 证书同时被其他网站使用时保留证书及其续期配置
sudo bash uninstall.sh --keep-certificate
```

删除范围包含部署目录、`mcy_shop` 数据库及其 localhost 用户、专属 Nginx 站点和 PHP-FPM 池、`mcy-shop` 系统用户、本站日志（含轮转日志）、ACME 文件、本站证书及其续期配置、续期重载钩子、部署记录和初始密码文件。预览仍需 root 权限，以读取受保护的部署记录。

共享的 Nginx、PHP、MariaDB、Certbot 软件包和续期定时器会保留，其他站点及数据库不受影响。DNS 记录、你上传到 `/root/mcy-shop` 等位置的原始源码、自行制作的备份及共享系统日志不在自动删除范围内。卸载中断后可重跑同一命令；记录缺失或资源归属不匹配时会停止，不猜测删除目标。

## 重跑与故障恢复

- 证书申请失败会明确退出，HTTP 站点和已初始化数据库会保留。检查 DNS（包括 AAAA）、端口和 `/var/log/letsencrypt/letsencrypt.log` 后重跑原命令。
- 已存在的非空目标目录、同名数据库/用户、非本脚本管理的配置会导致脚本停止，避免覆盖现有部署。脚本会安装/启用系统软件包，建议用于干净 VPS。
- SQL 含 `DROP TABLE`，因此脚本仅在首次创建的空数据库中导入一次。如果导入中途失败，脚本会停止自动恢复，要求人工检查，以免误删数据。**不要通过删除部署记录来强行重装**。
- 备份应包含数据库、整个程序目录（含上传文件/插件）、部署记录及凭据。升级前先备份，按项目升级流程操作；本脚本负责安装和配置，不能替代数据迁移或备份。

官方资料：[Debian PHP 8.4](https://packages.debian.org/trixie/php8.4-fpm)、[Nginx FastCGI](https://nginx.org/en/docs/http/ngx_http_fastcgi_module.html)、[Certbot](https://eff-certbot.readthedocs.io/en/stable/using.html)。
