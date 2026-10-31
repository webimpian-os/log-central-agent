<p align="center">
  <img src="docs/logo.svg" width="96" height="96" alt="log-central-agent logo">
</p>

<h1 align="center">log-central-agent</h1>

<p align="center">
  Watches every site on a RunCloud or Plesk server and reports problems to <a href="https://github.com/webimpian-os/log-central-portal">Log Central</a>.
</p>

<p align="center">
  <a href="https://github.com/webimpian-os/log-central-agent/actions/workflows/tests.yml"><img src="https://img.shields.io/github/actions/workflow/status/webimpian-os/log-central-agent/tests.yml?branch=main&label=tests&style=flat-square" alt="Tests"></a>
  <a href="https://github.com/webimpian-os/log-central-agent/releases/latest"><img src="https://img.shields.io/github/v/release/webimpian-os/log-central-agent?style=flat-square&color=6366f1" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/panels-RunCloud%20%7C%20Plesk-0ea5e9?style=flat-square" alt="Panels: RunCloud and Plesk">
  <a href="https://vector.dev"><img src="https://img.shields.io/badge/Vector-0.61.0-8b5cf6?style=flat-square" alt="Vector 0.61.0"></a>
  <img src="https://img.shields.io/badge/limits-%C2%BD%20CPU%20%C2%B7%20256%20MB-34d399?style=flat-square" alt="Limits: half a CPU core and 256 MB">
</p>

It reports three kinds of problems:

- **PHP errors:** a WordPress "critical error" page becomes an error you can see, instead of one nobody notices.
- **Failing sites:** at least half of a site's requests in a minute, and at least 5, getting a server error (5xx), like a broken page or a database that's down.
- **Traffic spikes:** a site getting 3,000 or more requests in a minute, with the top addresses, paths and user agents, so you can tell an attack from a busy day.

It runs once per server. Nothing is installed in WordPress, and the Log Central token never touches a site's files or database.

## How it works

![The agent reads each site's Apache and nginx logs, keeps real PHP errors, failing sites and traffic spikes, labels them with the site and sends them to Log Central](docs/how-it-works.svg)

For PHP errors, most of what the logs hold is noise. On one real server with 6 sites:

![Of 167,832 PHP messages, 2,036 were fatal errors, 1,055 were real errors once bots were dropped, and they formed 40 error groups](docs/php-errors.svg)

## What it detects

| Problem | Detected | How it shows up |
|---|---|---|
| PHP fatal or parse error, logged by Apache or nginx | ✅ Yes | One error group per site and code location, with the request and the stack trace. The plugin or theme is in the file path |
| PHP warnings, notices and deprecations | ➖ No, on purpose | Too noisy, and they don't break the page |
| Bots opening WordPress files directly | ➖ No, on purpose | Ignored: the site isn't broken |
| A site where most requests fail (500, 502, 503 or 504) | ✅ Yes | "Site failing", with the paths that failed |
| A single server error now and then | ➖ No, on purpose | Mostly bots probing paths that don't exist |
| nginx's own errors, like "upstream timed out" or PHP-FPM refusing connections | ⏳ Not yet | Their effect shows up as "Site failing" |
| A flood or DDoS on a site (3,000+ requests a minute) | ✅ Yes | "Traffic spike", with the top IPs, paths, user agents and status codes |
| A slow brute-force attack (say 200 logins a minute) | ⏳ Not yet | Below the traffic spike threshold |
| Slow pages | ⏳ Not yet | Needs request times in the web server logs |
| Server CPU, memory or disk | ➖ No | Use a server monitor such as Beszel |
| Blocking an attack | ➖ No | Detection only. Blocking stays with Cloudflare, Imunify360 or the panel's firewall |

## Install

As root on a RunCloud or Plesk server:

```
curl -fsSL https://raw.githubusercontent.com/webimpian-os/log-central-agent/v1.0.0/install.sh | sudo bash
```

It finds the panel itself, asks for the Log Central URL, app slug and app token, and checks them before changing anything. On a server that is neither, or looks like both, it stops without changing anything.

| Panel | Reads |
|---|---|
| RunCloud (NGINX + Apache or native NGINX) | `/home/*/logs/apache2/*_error.log`, `/home/*/logs/nginx/*_error.log`, `/home/*/logs/nginx/*_access.log` |
| Plesk (nginx in front of Apache) | `/var/www/vhosts/system/*/logs/` `error_log`, `proxy_error_log`, `proxy_access_log`, `proxy_access_ssl_log` |

## Update

Servers don't update automatically. A new release only reaches a server when you install it there.

To update a server, run the installer from the new tag. Settings and the token are kept:

```
curl -fsSL https://raw.githubusercontent.com/webimpian-os/log-central-agent/<new-tag>/install.sh | sudo bash
```

To update many servers from a checkout of the new tag, one at a time:

```
scripts/rollout.sh staging-server web-01 web-02
```

Update a staging server first, then one client server, then the rest.

## Server safety

| Risk | Protection |
|---|---|
| High CPU | Capped at half of one core, at the lowest priority, so PHP and MySQL always come first. Under load it falls behind and catches up later |
| Out of memory | Capped at 256 MB, with fixed limits on what it remembers during a flood. If it goes over, only the agent is restarted, never the sites |
| Disk full | Writes only a few KB. Its own logging is rate-limited |
| Log Central down | Stops reading and waits. Unsent errors stay in the log files and are sent once Log Central is back |
| Agent restart or crash | Picks up where Log Central last confirmed, so nothing is lost. A backlog is never counted as a traffic spike |
| Crash loop | Stops after 5 crashes in 10 minutes, then tries again every 15 minutes |
| Busy server | The installer refuses to run on low disk, low memory or high load, and stops the agent if the kernel isn't enforcing the limits above |

## Stress test

Vector 0.61.0 under the same limits as production (half a CPU core, 256 MB).

PHP errors, 100 sites:

| Scenario | Load | Avg CPU | Peak memory | Result |
|---|---|---|---|---|
| First install | 1 million lines (557 MB) already in the logs | 50% (the cap) | 74 MB | All read in 114 s |
| Error flood | 5,000 lines a second for 2 minutes | 31% | 70 MB | Kept up live |
| Log Central returning errors (503) | 5,000 lines a second for 1 minute | 18% | 69 MB | Retried, kept running |
| Log Central unreachable | 5,000 lines a second for 1 minute | 16% | 73 MB | Retried, kept running |
| Log Central back | 200 lines a second | 2% | 61 MB | Errors flowed again |

In total it read 2.2 million lines (1.2 GB) with a memory peak of 75 MB, no out-of-memory kills and no crashes.

Traffic, on a Plesk layout with 50 sites, 1% of requests ending in a PHP fatal error:

| Scenario | Load | Avg CPU | Peak memory | Result |
|---|---|---|---|---|
| Normal traffic | 1,000 requests a second for 2 minutes | 17% | 50 MB | Kept up live |
| DDoS on one site | 8,000 requests a second from random addresses, paths and user agents, for 2 minutes | 47% | 76 MB | Reported the spike, caught up 26 s after the attack stopped |
| Server-wide flood, 100 sites | 20,000 requests a second for 1 minute | 49% (the cap) | 92 MB | Reported the spike on all 100 sites. Fell behind and caught up 2 minutes after the flood stopped |
| Log Central down for 6 minutes | 2,000 requests a second | 6% | 73 MB | Paused reading, then sent the 175 errors that were waiting. No false spikes from the backlog |

In total it read 2.4 million requests (277 MB of logs) with a memory peak of 92 MB, no out-of-memory kills and no crashes.

For scale, the busiest real site on our two test servers peaked at 666 requests a minute, about 11 a second.

## Security

- The URL, app slug and token are readable only by the agent's own system user and root. Sites and their PHP code can't read them.
- The token can only send errors to one app. If it leaks, rotate it in Log Central and run the installer again.
- Plesk keeps each domain's logs readable only by root, so on Plesk the agent may read any file, but sees only `/var/www/vhosts/system`. Site files, Plesk's own secrets and `/etc/shadow` are hidden from it.

## Commands

```
systemctl status log-central-agent      # is it running?
journalctl -u log-central-agent -f      # what is it doing?
curl -fsSL https://raw.githubusercontent.com/webimpian-os/log-central-agent/v1.0.0/uninstall.sh | sudo bash
```

## Development

```
VECTOR=/path/to/vector scripts/test.sh     # run the tests
scripts/rollout.sh --url URL --app SLUG web-01 web-02   # install this checkout over SSH (token from LOG_CENTRAL_TOKEN)
```

To release: bump `AGENT_VERSION` in `install.sh` and the tags in this README, commit, tag the commit with the same version (e.g. `v1.0.1`), and push the tag. Then update the servers as above.
