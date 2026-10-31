# runcloud-log-central

Sends PHP fatal errors from every site on a RunCloud server to [Log Central](https://github.com/webimpian-os/log-central-portal), so a WordPress "critical error" page becomes an error you can see, instead of one nobody notices.

It runs once per server. Nothing is installed in WordPress, and the Log Central token never touches a site's files or database.

## How it works

![WordPress sites write PHP fatal errors to Apache's error logs; the agent keeps only real errors, labels them with the site and sends each one to Log Central at most once per 5 minutes](docs/how-it-works.svg)

## Install

On a RunCloud server using the NGINX + Apache stack, as root:

```
curl -fsSL https://raw.githubusercontent.com/webimpian-os/runcloud-log-central/v1.0.0/install.sh | sudo bash
```

It asks for the Log Central URL, app slug and app token, and checks them before changing anything.

Native NGINX sites (without Apache) aren't supported yet.

## Update

Servers don't update automatically. A new release only reaches a server when you install it there.

To update a server, run the installer from the new tag. Settings and the token are kept:

```
curl -fsSL https://raw.githubusercontent.com/webimpian-os/runcloud-log-central/<new-tag>/install.sh | sudo bash
```

To update many servers from a checkout of the new tag, one at a time:

```
scripts/rollout.sh staging-server web-01 web-02
```

Update a staging server first, then one client server, then the rest.

## Server safety

| Risk | Protection |
|---|---|
| High CPU | Capped at half of one core, at the lowest priority, so PHP and MySQL always come first |
| Out of memory | Capped at 256 MB. If it goes over, only the agent is restarted, never the sites |
| Disk full | Writes only a few KB. Pending errors stay in memory, and its own logging is rate-limited |
| Log Central down | Retries in the background, then drops errors. It never blocks |
| Crash loop | Stops after 5 crashes in 10 minutes |
| Busy server | The installer refuses to run on low disk, low memory or high load, and stops the agent if the kernel isn't enforcing the limits above |

## Stress test

Vector 0.61.0 under the same limits as production (half a CPU core, 256 MB), with 100 sites:

| Scenario | Load | Avg CPU | Peak memory | Result |
|---|---|---|---|---|
| First install | 1 million lines (557 MB) already in the logs | 50% (the cap) | 74 MB | All read in 114 s |
| Error flood | 5,000 lines a second for 2 minutes | 31% | 70 MB | Kept up live |
| Log Central returning errors (503) | 5,000 lines a second for 1 minute | 18% | 69 MB | Retried, kept running |
| Log Central unreachable | 5,000 lines a second for 1 minute | 16% | 73 MB | Retried, kept running |
| Log Central back | 200 lines a second | 2% | 61 MB | Errors flowed again |

In total it read 2.2 million lines (1.2 GB) with a memory peak of 75 MB, no out-of-memory kills and no crashes, and wrote only 55 lines to its own log. Log Central never received more than 100 errors in one request.

For scale, the 6 real sites behind the numbers in the diagram logged about 2,000 fatal errors in their current log files. The flood test wrote 5,000 lines every second.

## Security

- The URL, app slug and token are readable only by the agent's own system user and root. Sites and their PHP code can't read them.
- The token can only send errors to one app. If it leaks, rotate it in Log Central and run the installer again.

## Commands

```
systemctl status runcloud-log-central      # is it running?
journalctl -u runcloud-log-central -f      # what is it doing?
curl -fsSL https://raw.githubusercontent.com/webimpian-os/runcloud-log-central/v1.0.0/uninstall.sh | sudo bash
```

## Development

```
VECTOR=/path/to/vector scripts/test.sh     # run the tests
scripts/rollout.sh --url URL --app SLUG web-01 web-02   # install this checkout over SSH (token from LOG_CENTRAL_TOKEN)
```

To release: bump `RLC_VERSION` in `install.sh` and the tags in this README, commit, tag the commit with the same version (e.g. `v1.0.1`), and push the tag. Then update the servers as above.
