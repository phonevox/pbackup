# Quickstart

1. Download the latest tag (one liner)
```sh
curl -s https://api.github.com/repos/phonevox/pbackup/releases/latest | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",/\1/' | xargs -I {} curl -skL https://github.com/phonevox/pbackup/archive/refs/tags/{}.tar.gz | tar xz --transform="s,^[^/]*,pbackup,"; find pbackup -type f -name "*.sh" -exec chmod +x {} \;
```

2. Access the repository's folder
```
cd ./pbackup
```

3. Install pbackup tool to your path, or use it directly
```sh
./pbackup --install # adds to system path (specifically /usr/sbin/pbackup), call with 'pbackup -h'
./pbackup --update # update to most recent github tag. not necessary if you just cloned the repository
./pbackup --help # shows how to use the app
```

4. After installed, you can call it from anywhere, using:
```sh
pbackup --help # shows how to use the app
pbackup -v # checks the current version
```

5. If you installed the tool, you can use the pre-made backup scripts. Before using them, you need to set up the rclone configuration:
> Follow the configuration steps, and create a remote<br>
> If you already have a remote configured in rclone, you can skip this step


```sh
pbackup --config # you might have to run this command twice!
```

6. After you have the tool installed to your path, and a remote configured in rclone (pbackup --config / rclone config), you can use the pre-made backup scripts:
> issabel-backup.sh is premade for generating issabelpbx's backups (using our backup engine. it also works without our engine) and
> magnus-backup.sh is premade for generating magnusbilling backups

```sh
  ./scripts/issabel-backup.sh <remote> 
# ./scripts/issabel-backup.sh "mega:/backup-$(date +"%d-%m-%Y")"

  ./scripts/magnus-backup.sh <remote> 
# ./scripts/magnus-backup.sh "mega:/backup-$(date +"%d-%m-%Y")"
```
