# MikroTik AdList (HaGeZi edition)

DNS blocklists from [HaGeZi's DNS Blocklists](https://github.com/hagezi/dns-blocklists), converted to hosts format for the [MikroTik RouterOS DNS AdList feature](https://help.mikrotik.com/docs/spaces/ROS/pages/37748767/DNS#DNS-adlistAdlist).

[![Update DNS Filters](https://github.com/Maxren2/mikrotik-adlist/actions/workflows/update-filters.yaml/badge.svg)](https://github.com/Maxren2/mikrotik-adlist/actions/workflows/update-filters.yaml)

> Fork of [IgorKha/mikrotik-adlist](https://github.com/IgorKha/mikrotik-adlist). The upstream project pulls whatever the AdGuard Hostlists Registry mirrors; this fork pulls **directly from hagezi**, so lists are current and the full catalogue is available rather than the registry's subset.

## Why this conversion is needed

hagezi publishes `adblock/`, `wildcard/`, `dnsmasq/`, `rpz/` and others — but **no hosts-format directory**. RouterOS AdList wants hosts format, so [`transform.sh`](transform.sh) rewrites each rule:

```
||example.com^   ->   0.0.0.0 example.com
```

## Data source

- **Upstream**: <https://github.com/hagezi/dns-blocklists> (`adblock/` directory)
- **Which lists**: defined in [`filters.json`](filters.json) — edit that file to add or remove lists
- **Update frequency**: weekly, Sundays 06:00 UTC (or run the workflow manually via *Actions → Update DNS Filters → Run workflow*)

## Usage

Each list is at:

```
https://raw.githubusercontent.com/Maxren2/mikrotik-adlist/main/hosts/<name>.txt
```

On RouterOS 7.15+:

```routeros
/ip/dns/adlist add url="https://raw.githubusercontent.com/Maxren2/mikrotik-adlist/main/hosts/hagezi_pro.txt" ssl-verify=no
/ip/dns/set allow-remote-requests=yes cache-size=51200KiB
/ip/dns/adlist/reload
```

Check what actually loaded:

```routeros
/ip/dns/adlist print stats
/ip/dns/cache print count-only
```

> [!IMPORTANT]
> `cache-size` must be large enough to hold the list, or entries are silently dropped. Budget roughly **80–100 bytes per domain**: ~220k domains (Pro) needs ≈ 20 MiB, plus headroom for the normal DNS cache. Check free RAM with `/system/resource/print` before loading a big list.

> [!TIP]
> **Pick one main list, not several.** `light` → `multi` → `pro` → `pro.plus` → `ultimate` are cumulative supersets — stacking them wastes RAM without blocking anything extra. Add *specialised* lists (tif, popupads, gambling, nsfw…) on top of your one main choice.

## Available lists

**Main** — cumulative, pick exactly one:

| File | Entries | Notes |
| --- | ---: | --- |
| `hagezi_light` | ~42k | Ads, tracking, metrics. Lowest false-positive risk |
| `hagezi_multi` | ~183k | Balanced: + phishing, malware, scam, cryptojacking |
| `hagezi_pro` | ~219k | **Recommended default** |
| `hagezi_pro_plus` | ~242k | Aggressive; occasional false positives |
| `hagezi_ultimate` | ~273k | Strictest; will break some apps |

`hagezi_pro_mini`, `hagezi_pro_plus_mini`, `hagezi_ultimate_mini` are size-optimised variants for low-RAM routers.

**Threat intelligence** — malware, phishing, cryptojacking:

| File | Entries | Notes |
| --- | ---: | --- |
| `hagezi_tif_mini` | ~171k | Safe on most hardware |
| `hagezi_tif_medium` | ~388k | Needs a well-specced router |
| `hagezi_tif` | ~2.17M | **~180 MB RAM** — only for high-RAM devices |

**Specialised**: `hagezi_popupads`, `hagezi_fake`, `hagezi_anti_piracy`, `hagezi_gambling`(`_medium`/`_mini`), `hagezi_nsfw`, `hagezi_social`, `hagezi_doh`, `hagezi_doh_top`, `hagezi_doh_vpn_proxy_bypass`, `hagezi_dyndns`, `hagezi_hoster`, `hagezi_urlshortener`, `hagezi_nosafesearch`, `hagezi_referral`

**Native device trackers**: `hagezi_native_` + `amazon`, `apple`, `huawei`, `lgwebos`, `oppo_realme`, `roku`, `samsung`, `tiktok`, `tiktok_extended`, `vivo`, `winoffice`, `xiaomi`

## Deliberately excluded

Some hagezi lists cannot work as DNS hosts entries and are left out of `filters.json` on purpose:

- **`*-ips.txt`** (`doh-ips`, `nameserver-ips`, `tif-ips`) — IP addresses, not domains. Converting gives `0.0.0.0 1.1.1.1`, which is meaningless to a DNS resolver. Use `/ip/firewall/address-list` instead.
- **`whitelist-*.txt`**, **`spam-tlds-adblock-allow.txt`** — allow rules (`@@||domain^`). Converting them would *block* the domains they exist to unblock.
- **`spam-tlds*.txt`** — bare TLDs (`||actor^`). A hosts entry matches an exact FQDN, so `0.0.0.0 actor` blocks nothing. TLD-wide blocking needs regex rules, not an adlist.

## Local run

Requires `bash`, `jq`, `curl`:

```bash
./transform.sh ./filters.json      # writes hosts/
```

## License

Scripts, automation and documentation: MIT (see [LICENSE](LICENSE)).

Blocklist data is derived from [hagezi/dns-blocklists](https://github.com/hagezi/dns-blocklists) and remains subject to [its license](https://github.com/hagezi/dns-blocklists/blob/main/LICENSE).
