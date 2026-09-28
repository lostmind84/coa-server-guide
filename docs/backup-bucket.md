# Offsite backup bucket (S3, buckets.ninja)

The build server uploads every verified backup set ([backup.md](backup.md)) to an S3 bucket, encrypted on the build
server with `rclone crypt` and locked against deletion. The bucket is the copy that survives the loss of both
production and the build server ([restore.md](restore.md)).

Status: tested on 2026-09-28 against the real bucket from an Ubuntu 24.04 build-server container with rclone
v1.75.1: encrypted upload, `cryptcheck`, per-object GOVERNANCE lock, refused deletions, lifecycle configuration
stored and read back, full restore from the bucket alone. Test objects lived under `_test/` with 15-minute locks
and were deleted afterwards. Not observed yet: lifecycle rules actually expiring objects.

## What the provider offers (measured)

buckets.ninja is S3 on MinIO (`provider = Minio`), €7.99 per TB per month (one 1 TB block minimum), uploads and
write requests free, 1 TB of egress included per TB. Buckets are created in the web panel.

| Test on the bucket (object lock enabled at creation) | Result |
| --- | --- |
| `get-bucket-versioning` / `get-object-lock-configuration` | `Enabled` / `ObjectLockEnabled: Enabled`, no default retention |
| upload through `rclone crypt` with `--s3-object-lock-mode GOVERNANCE` | object stored with its retention date |
| delete or overwrite a locked version | refused: `Object is WORM protected and cannot be overwritten` |
| delete a locked version with `--bypass-governance-retention` | refused: `AccessDenied` |
| delete without a version id | only adds a delete marker; the locked version stays |
| **shorten a retention with `--bypass-governance-retention`** | **accepted**; the version could be deleted once the shortened date had passed |
| lifecycle rules filtered by prefix | accepted and read back identical |

What this protects against: mistakes, a broken script, ransomware that deletes or overwrites files. What it does
not protect against: someone holding the access key who knows to shorten the retention first and wait. The key
therefore lives only on the build server (never on production). COMPLIANCE mode, which would close this, is not
offered by the provider; an access key without the bypass permission would, if the provider adds one.

## Bucket setup (once, in the panel)

1. Create the bucket (`<account prefix>-backups`) with **Object lock (WORM)** ticked. It can only be enabled at
   creation and turns versioning on.
2. Create an access key and download `rclone.conf` (*Buckets → Download rclone.conf*). Its three extra settings are
   required: `no_check_bucket = true` (keys cannot create buckets), `upload_cutoff = 0` and
   `use_multipart_etag = false` (with encryption at rest the ETag is not the MD5; without them rclone deletes what it
   just uploaded as "corrupted"). Never add `--ignore-checksum`.
3. Lifecycle rules, applied once with the AWS CLI (from a container, nothing to install):

```bash
cat > lifecycle.json <<'EOF'
{"Rules":[
 {"ID":"hourly","Status":"Enabled","Filter":{"Prefix":"hourly/"},"Expiration":{"Days":2},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"daily","Status":"Enabled","Filter":{"Prefix":"daily/"},"Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"weekly","Status":"Enabled","Filter":{"Prefix":"weekly/"},"Expiration":{"Days":84},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"predeploy","Status":"Enabled","Filter":{"Prefix":"predeploy/"},"Expiration":{"Days":90},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"delete-markers","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"ExpiredObjectDeleteMarker":true}}
]}
EOF
# bn.env holds AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (from rclone.conf) and AWS_DEFAULT_REGION=us-east-1, mode 600
docker run --rm --env-file bn.env -v "$PWD":/w:ro amazon/aws-cli --endpoint-url https://s3.buckets.ninja \
  s3api put-bucket-lifecycle-configuration --bucket <bucket> --lifecycle-configuration file:///w/lifecycle.json
docker run --rm --env-file bn.env amazon/aws-cli --endpoint-url https://s3.buckets.ninja \
  s3api get-bucket-lifecycle-configuration --bucket <bucket>
```

Each object is locked for as long as its folder's expiration. When a set expires, the rule adds a delete marker;
the locked version becomes non-current and is removed a day later, once its lock has passed. `static/` has no rule:
it stays until you delete it by hand after its lock (365 days).

## Build server setup

rclone from rclone.org (tested version v1.75.1; the object lock options are recent, the Ubuntu 24.04 package was not
tested):

```bash
curl -fsSL https://rclone.org/install.sh | sudo bash
rclone version
```

As the build user:

```bash
install -d -m 700 ~/.config/rclone
install -m 600 ~/Downloads/rclone.conf ~/.config/rclone/rclone.conf
```

Choose a long passphrase, store it in your password manager **before** anything is uploaded, then add the crypt
remote (the passphrase is typed interactively, it does not end up in the shell history):

```bash
read -rs -p "rclone crypt passphrase: " PASS; echo
cat >> ~/.config/rclone/rclone.conf <<EOF

[coa-backups]
type = crypt
remote = buckets-ninja:<bucket>
filename_encryption = standard
directory_name_encryption = false
password = $(rclone obscure "$PASS")
EOF
unset PASS
rclone lsf coa-backups:          # empty listing, no error
```

`directory_name_encryption = false` keeps the folder names (`hourly/`, `daily/`, set timestamps) readable so the
lifecycle rules can match them; file names and contents are encrypted. **Without the passphrase the backups cannot
be read by anyone, including you.** Keep in the password manager: the passphrase, and the whole `rclone.conf`
(access key, secret, bucket name).

Push configuration, `/srv/coa-build/coa-backup-push.conf`:

```bash
SETS=/srv/coa-build/backups
REMOTE=coa-backups:
STATIC_PATHS="/srv/coa-build/static/main-20260919-b3717c137 /srv/coa-build/static/repack-dump"
```

`STATIC_PATHS` are folders uploaded once to `static/<folder name>/` (client data of the version in use, a folder
holding the repack `databases.sql.gz`). Add the new client data folder when the data version changes.

| Setting | Default | Meaning |
| --- | --- | --- |
| `SETS` | required | local backup root (`DEST` of the pull configuration) |
| `REMOTE` | required | rclone crypt remote |
| `LOCK_HOURLY`, `LOCK_DAILY`, `LOCK_WEEKLY`, `LOCK_PREDEPLOY` | `2 days`, `30 days`, `84 days`, `90 days` | lock length per kind (GNU `date` offsets); keep them equal to the lifecycle rules |
| `LOCK_STATIC` | `365 days` | lock length for `STATIC_PATHS` |
| `STATIC_PATHS` | empty | folders uploaded once |
| `MAX_HOURLY_AGE_HOURS` | `2` | status fails when the newest uploaded hourly set is older |
| `RCLONE` | `rclone` | rclone command |

Schedule: one cron line with the pull, see backup.md.

## What the push does

1. For each local set not uploaded yet (`$SETS/.pushed/<kind>-<timestamp>` markers): `rclone copy` through the crypt
   remote with `--s3-object-lock-mode GOVERNANCE --s3-object-lock-retain-until-date <now + lock>
   --s3-object-lock-set-after-upload`, then `rclone cryptcheck` (decrypts the checksums and compares them with the
   local files). The marker is written only if both succeed.
2. A daily set taken on a Sunday (UTC) is uploaded a second time to `weekly/`.
3. `STATIC_PATHS` folders not uploaded yet.
4. Markers of sets gone from the local rotation are removed; the push never deletes anything in the bucket.
5. Status; exit code 1 if any upload failed or the newest uploaded hourly set is too old.

Measured: 94 MB daily set uploaded and checked in about 1 minute from the test machine (depends on the uplink);
hourly set in a few seconds; a second run with nothing new uploads nothing.

## Daily operation

```bash
coa-backup-push.sh /srv/coa-build/coa-backup-push.conf --status
rclone lsf coa-backups:daily/                     # sets in the bucket, decrypted names
rclone lsf -R buckets-ninja:<bucket>/daily/ | head   # what the provider sees
```

| Message | Meaning | Action |
| --- | --- | --- |
| `ALERT: push of <kind>/<set> failed` | upload or `cryptcheck` failed | run again (next cron run retries automatically); on repeated failures check `rclone lsf coa-backups:`, the key in the panel (a key is suspended when the wallet is empty) |
| `ALERT: newest offsite hourly set is older than 2h` | pushes stopped | check the pull status first: nothing new to push if production backups stopped |
| `AccessDenied` on upload | bucket name or key wrong, or key suspended for an unpaid balance | panel |

Cost check: the bucket's size is visible in the panel; with the default retention it stays in the tens of GB.
