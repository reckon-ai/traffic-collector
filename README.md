# traffic-collector

Pull mobile data usage from a fleet of Teltonika RUT routers through Orange Pi
reverse SSH tunnels.

## How it works

```
Reckon VPS (SSH bastion)
  └→ /root/.ssh/config → Orange Pi host alias (localhost:<port>)
     └→ sshpass → router at 172.29.1.1
        └→ ubus call mdcollect get → rx/tx bytes
```

One SSH session per router. Discovers modem params from `gsmctl -E`, pulls all 4
periods (day/week/month/total) in a single call.

## Prerequisites

- `sshpass` on the bastion and on every Orange Pi
- `/root/.ssh/reckon` key on the bastion (added to Orange Pis)
- `RECKEY_PASS` env var set to the key's passphrase
- Mapping file with `hostname=bb-<epoch>` entries for each router

## Quick start

Generate the SSID mapping from the fleet CSV:

```sh
python3 generate-mapping.py ~/Downloads/RK\ Machine\ Managmennt\ -\ MAIN.csv > mapping.txt
```

Run against a single host:

```sh
RECKEY_PASS=... ./mdcollect.sh -m mapping.txt reckon-vending-0001
```

Run against the entire fleet (auto-discovers from SSH config):

```sh
RECKEY_PASS=... ./mdcollect.sh -m mapping.txt -a -o /var/log/traffic-collector.jsonl
```

## Output

One JSON line per router per run:

```json
{
  "host": "reckon-vending-0001",
  "ssid": "bb-1763727640",
  "mac": "00:1e:42:62:b5:f9",
  "usage": {
    "day":   {"rx": 0, "tx": 0},
    "week":  {"rx": 0, "tx": 0},
    "month": {"rx": 0, "tx": 0},
    "total": {"rx": 0, "tx": 0}
  },
  "ts": "2026-06-12T13:10:52Z"
}
```

## Credential chain

1. **Bastion → Orange Pi**: SSH key at `/root/.ssh/reckon`, passphrase in `RECKEY_PASS`
2. **Orange Pi → Router**: password derived from the `bb-<epoch>` SSID
   - XOR with cypher → SHA-384 → hex substring → 9-char wifi pass
   - Root pass = `BB` + wifi pass
   - Algorithm must match `../rut/teltonika_credentials.sh` byte-for-byte

## Adding a new router

1. Router gets provisioned → SSID is `bb-<epoch>`
2. Orange Pi reverse tunnel gets set up → entry added to `/root/.ssh/config`
3. CSV gets updated with the new `BB` column entry
4. Regenerate mapping: `python3 generate-mapping.py fleet.csv > mapping.txt`
5. Next cron run picks it up automatically (with `-a` flag)

## Options

| Flag | Description |
|------|-------------|
| `-m <file>` | SSID mapping file (required) |
| `-o <file>` | Append JSONL output to file |
| `-a`, `--all` | Auto-discover hosts from `/root/.ssh/config` |
| `hostname ...` | Pull specific hosts only |

## Notes

- Unmapped hosts are logged to stderr as `SKIP <host> — no bb-* SSID in mapping`
- `mdcollect`'s `get` method doesn't support the `total` period — `get_raw_total` is used instead
- RUT240 and RUT241 require legacy SSH KEX options (handled automatically)
- All routers are assumed to be at `172.29.1.1` (the Orange Pi's default gateway)
