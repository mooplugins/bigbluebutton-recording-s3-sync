# BBB recording sync to Amazon S3

Two Ruby scripts share `/etc/default/bbb-s3-sync` and the same S3 key layout.

| Script | When it runs | What it does |
|--------|----------------|--------------|
| `post_publish_sendtos3.rb` | BigBlueButton `post_publish`, once per format, after that format is written under `published/` | Uploads that recording's files for the format BBB just finished |
| `bbb-s3-sync.rb` | Cron (hourly) | Lists the bucket prefix, walks every local recording, uploads anything still missing, then deletes orphaned S3 objects |

`post_publish_sendtos3.rb` is the path that runs as soon as a format is published. `bbb-s3-sync.rb` is the catch-up: it fills gaps the hook missed and removes objects that no longer exist locally.

## Config

Install the env file on the BBB host (no extension):

```bash
sudo cp bbb-s3-sync.env.example /etc/default/bbb-s3-sync
sudo chmod 640 /etc/default/bbb-s3-sync
sudo chown root:bigbluebutton /etc/default/bbb-s3-sync
```

Both scripts load this file into `ENV` on startup. A variable already set in the environment is left as-is.

| Variable | Required | Default |
|----------|----------|---------|
| `BBB_S3_BUCKET` | yes | — |
| `BBB_S3_REGION` | yes | — |
| `AWS_ACCESS_KEY_ID` | post_publish: yes. Cron: yes, unless the host has an IAM role | — |
| `AWS_SECRET_ACCESS_KEY` | same as the access key | — |
| `BBB_S3_PREFIX` | no | `bbb-recordings` |
| `BBB_PUBLISHED_ROOT` | no | `/var/bigbluebutton/published` |
| `BBB_S3_LOG` | no | `/var/log/bigbluebutton/bbb-s3-sync.log` |
| `BBB_S3_POST_PUBLISH_LOG` | no | `/var/log/bigbluebutton/sendtos3.log` |
| `BBB_S3_PREFIX_EXTERNAL` | no | `false` (post_publish only) |
| `BBB_S3_POST_PUBLISH_DISABLED` | no | `false` (post_publish only; `true` exits without uploading) |
| `BBB_S3_ENV_FILE` | no | `/etc/default/bbb-s3-sync` |

Leave `BBB_S3_PREFIX` empty to store objects at the bucket root:

```text
s3://<bucket>/<recording_id>/video-0.m4v
```

`BBB_S3_PREFIX_EXTERNAL=true` makes the post_publish hook put the external meeting id in front of the recording id (`<external_id>/<recording_id>/...`). It reads that id from `/var/bigbluebutton/recording/raw/<id>/events.xml`. The cron script does not use this variable.

## S3 keys

Playback files stay at the recording root. Format `metadata.xml` and the presentation/statistics trees keep a relative path. `recording.zip` is left alone: neither script uploads or deletes it. Dotfiles and `*.tmp` are skipped.

```text
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/video-0.m4v
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/video-1.mp4
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/notes.pdf
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/audio.ogg
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/deskshare.webm
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/video/metadata.xml
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/notes/metadata.xml
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/podcast/metadata.xml
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/screenshare/metadata.xml
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/presentation/video/webcams.webm
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/presentation/shapes.svg
s3://$BBB_S3_BUCKET/$BBB_S3_PREFIX/<recording_id>/statistics/...
```

| Format | Local directory | S3 path under `<recording_id>/` |
|--------|-----------------|----------------------------------|
| video | `published/video/<id>/` | `video-N.m4v` / `video.mp4`, plus `video/metadata.xml` |
| notes | `published/notes/<id>/` | `notes.pdf`, plus `notes/metadata.xml` |
| podcast | `published/podcast/<id>/` | `audio.ogg` / `audio.webm` / `audio.mp3`, plus `podcast/metadata.xml` |
| screenshare | `published/screenshare/<id>/` | `deskshare` or `screenshare` `.webm`/`.mp4`, plus `screenshare/metadata.xml` |
| presentation | `published/presentation/<id>/` | `presentation/<relative path>` (whole tree) |
| statistics | `published/statistics/<id>/` | `statistics/<relative path>` (whole tree, if installed) |

## Install

On the BBB host, from this directory:

```bash
# Cron sync (needs the aws-sdk-s3 gem)
sudo gem install aws-sdk-s3
sudo install -o bigbluebutton -g bigbluebutton -m 755 \
  bbb-s3-sync.rb /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb

# Post-publish hook. BBB runs every executable in this directory.
sudo install -o bigbluebutton -g bigbluebutton -m 755 \
  post_publish_sendtos3.rb \
  /usr/local/bigbluebutton/core/scripts/post_publish/post_publish_sendtos3.rb
```

If an older copy is still installed as `1_sendtos3.rb`, remove it. BBB would run both hooks and upload the same format twice.

```bash
sudo rm -f /usr/local/bigbluebutton/core/scripts/post_publish/1_sendtos3.rb
```

`post_publish_sendtos3.rb` uses Ruby stdlib SigV4 plus the `optimist` gem that ships with BigBlueButton. It needs `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` in the env file. An IAM role alone is not enough for that hook.

`/usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb` uses `aws-sdk-s3`, which reads the same keys and also works with an IAM instance role when the keys are omitted.

## Cron

Install an hourly job for the `bigbluebutton` user. The script lives next to the other BBB core scripts.

```bash
sudo tee /etc/cron.d/bbb-s3-sync >/dev/null <<'EOF'
0 * * * * bigbluebutton . /etc/default/bbb-s3-sync; /usr/bin/flock -n /var/lock/bbb-s3-sync.lock /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb >> /var/log/bigbluebutton/bbb-s3-sync.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/bbb-s3-sync
```

The line in `/etc/cron.d/bbb-s3-sync` is:

```cron
0 * * * * bigbluebutton . /etc/default/bbb-s3-sync; /usr/bin/flock -n /var/lock/bbb-s3-sync.lock /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb >> /var/log/bigbluebutton/bbb-s3-sync.log 2>&1
```

`flock -n` skips the run when a previous sync is still going. It does not wait for recordings to finish. BBB only places a recording under `published/<format>/<id>/` after that format's publish step is done, and the post_publish hook is what runs at that moment.

## Run the cron sync by hand

Run this on the BBB host. `--dry-run` lists the actions and leaves S3 unchanged. Use it before a real run.

```bash
sudo -u bigbluebutton /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb --dry-run
sudo -u bigbluebutton /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb --help
```

From a checkout, before the script is installed:

```bash
ruby bbb-s3-sync.rb --dry-run
ruby bbb-s3-sync.rb
```

The script reads `/etc/default/bbb-s3-sync` when that file is readable. To pass settings for one run:

```bash
BBB_S3_BUCKET=my-bbb-recordings \
BBB_S3_REGION=ap-southeast-2 \
BBB_S3_PREFIX=bbb-recordings \
BBB_PUBLISHED_ROOT=/var/bigbluebutton/published \
AWS_ACCESS_KEY_ID=... \
AWS_SECRET_ACCESS_KEY=... \
ruby bbb-s3-sync.rb --dry-run
```

| Flag | Meaning |
|------|---------|
| `--dry-run` | Log only. No upload or delete |
| `--skip-delete` | Upload missing files and leave existing S3 objects in place |
| `--upload-limit=N` | Upload at most N missing files this run; defer the rest |
| `--recording-limit=N` | Upload for at most N recordings that still need files |

First backfill, in batches, with deletes held back:

```bash
sudo -u bigbluebutton /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb --skip-delete --upload-limit=50
sudo -u bigbluebutton /usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb --skip-delete --recording-limit=25
```

After the backlog is up, the normal command is `/usr/local/bigbluebutton/core/scripts/bbb-s3-sync.rb` with no flags. Limits still scan every local recording and every S3 key, so orphan detection stays correct. Only the uploads are capped.

Logs go to the terminal and to `BBB_S3_LOG`.

### What one cron run does

Every run covers the whole library:

1. List every object under the S3 prefix (`list_objects_v2`, 1,000 keys per call) and keep the keys in memory.
2. Walk every recording directory under `published/`.
3. For each managed file, look up its key in that list. A key that is already present is logged as `Skip (already in S3)` and left as-is. A missing key is uploaded.
4. Delete S3 objects whose recording is gone locally, and delete stale managed keys that are no longer in the local file list.

A library of 500 recordings is scanned on every run, including recordings that are already in S3. The S3 cost of that scan is the list calls. File checks after the list are in memory. A new recording is uploaded on top of that full scan; the older recordings are checked and skipped.

The "already in S3" check is the object key. A later local rewrite of the same filename is left in place until the S3 object is removed.

## Run the post_publish hook by hand

BBB calls the hook itself, once per format:

```text
post_publish_sendtos3.rb -m <recording_id> -f <format>
```

Formats it uploads: `video`, `notes`, `podcast`, `screenshare`, `presentation`, `statistics`. Any other format logs a skip and exits 0.

To upload one format for one recording from the checkout:

```bash
sudo -u bigbluebutton ruby post_publish_sendtos3.rb -m <recording_id> -f video
```

This uploads immediately. There is no dry-run flag on the hook. Output is appended to `BBB_S3_POST_PUBLISH_LOG` (`/var/log/bigbluebutton/sendtos3.log` unless that variable is set). Set `BBB_S3_POST_PUBLISH_DISABLED=true` in the env file to make the hook exit without uploading.
