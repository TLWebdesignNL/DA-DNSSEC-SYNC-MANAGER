# DA DNSSEC Sync Manager

A DirectAdmin plugin that automatically syncs DNSSEC keys to your domain registrar after every DNSSEC signing event. Supports ODR (Open Domain Registry) and OXXA.

---

## How it works

When DirectAdmin signs a domain zone, it fires a post-sign hook. This plugin installs a handler for that hook that:

1. Reads the ZSK and KSK key files from `/var/named/`
2. Looks up the domain owner and their reseller in DirectAdmin
3. Loads the reseller's registrar credentials
4. Compares the local keys against what the registrar has on file
5. Updates the registrar if anything differs
6. Writes a per-domain status JSON file and sends a DA notification on success or failure

Each reseller configures their own registrar and credentials through the plugin UI — no SSH access required after initial installation.

---

## Requirements

- DirectAdmin with PHP CGI support
- `jq` — required for all registrars
- `curl` — required for all registrars
- `xmllint` (`libxml2-utils`) — required for OXXA only

---

## Installation

1. Go to **Admin Panel → Plugin Manager**
2. Upload `da_dnssec_sync_manager.tar.gz` or point to the download URL
3. Click **Install**

The install script will:
- Set correct ownership and permissions
- Create the `data/` directory with the required subdirectories
- Seed the TLD exception list with defaults (`com`, `care`)
- Install the sync script at `/usr/local/directadmin/scripts/custom/da-odr-dnssec-sync.sh`
- Create or update `/usr/local/directadmin/scripts/custom/dnssec_sign_post.sh` to call the sync script

After installation, each reseller needs to configure their registrar credentials via the plugin UI before syncing will work.

---

## Registrar setup

### ODR (Open Domain Registry)

In the DA panel, go to **Plugin → Credentials** and select **ODR**. Enter your ODR public key and private key. These are available from your ODR account.

### OXXA

In the DA panel, go to **Plugin → Credentials** and select **OXXA**. Enter your OXXA API username and password.

Requires `xmllint` on the server:
```bash
apt install libxml2-utils   # Debian/Ubuntu
yum install libxml2         # CentOS/RHEL
```

---

## Admin panel

### Domain Exceptions
Domains added here are skipped entirely by the sync script — no API call is made. Useful for domains that are intentionally not registered at the configured registrar.

Each entry supports:
- **Reason** — optional note explaining why the domain is excluded
- **Expires** — optional date after which the exclusion is automatically ignored

### TLD Exceptions
TLDs listed here skip the pubkey verification step after a successful registrar update. Used for registrars that don't return pubkey data in their update response (e.g., `.com` at ODR).

### Credentials
Configure your own registrar credentials (used for domains directly under the admin account). Also shows a table of which resellers have credentials configured and which registrar they use.

### Status
A dashboard showing the last sync result for every domain that has been processed. Statuses:
- **OK** — keys are in sync
- **Excluded** — domain is on the exclusion list
- **Error** — sync failed, with an error message

### Logs
Displays the last 200 lines of `/var/log/da-odr-dnssec-sync.log` with a live filter. Admin-only since the log contains API tokens.

---

## Reseller panel

Resellers have access to:
- **Domain Exceptions** — manage exclusions for their own domains only
- **Credentials** — configure their own registrar credentials (registrar, API keys/passwords)

---

## Upgrading

Go to **Admin Panel → Plugin Manager** and click **Update**. The plugin fetches the latest tarball from GitHub and runs `update.sh`, which reapplies permissions and updates the sync script.

---

## Uninstalling

Go to **Admin Panel → Plugin Manager** and click **Uninstall**. The uninstall script:
- Backs up `data/excluded.txt` to `/usr/local/directadmin/scripts/custom/`
- Removes the plugin files
- Removes the managed hook from `dnssec_sign_post.sh` (or removes the file if it was created entirely by this plugin)

The sync script at `/usr/local/directadmin/scripts/custom/da-odr-dnssec-sync.sh` is left in place so existing hook references continue to work.

---

## Data files

| File | Description |
|------|-------------|
| `data/excluded.txt` | Domain exclusion list — one entry per line |
| `data/tld_exceptions.txt` | TLD exception list — one TLD per line |
| `data/credentials/<user>.conf` | Per-reseller registrar credentials (chmod 600) |
| `data/sync/<domain>.json` | Last sync status per domain |

---

## Credits

Inspired by [DNSSEC_da_oxxa.sh](https://github.com/jordivn/Webs-Systems-Scripts/blob/main/DNSSEC_da_oxxa.sh) by Jordi van Nistelrooij @ Webs en Systems.

---

## License

GNU General Public License version 3 or later.
