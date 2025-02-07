# Quickstart

Download the latest tag (one liner)
```sh
curl -s https://api.github.com/repos/phonevox/pbackup/releases/latest | grep '"tag_name":' | sed 's/.*"tag_name": "\(.*\)",/\1/' | xargs -I {} curl -skL https://github.com/phonevox/pbackup/archive/refs/tags/{}.tar.gz | tar xz --transform="s,^[^/]*,pbackup,"
```

Access the repository's folder
```
cd ./pbackup
```

Install pbackup tool to your path, or use it directly
```sh
chmod +x ./*.sh ./lib/*.sh ./scripts/*.sh # this is necessary! script has to be executable
./pbackup --install # adds to system path (specifically /usr/sbin/pbackup), call with 'pbackup -h'
./pbackup --update # update to most recent github tag. not necessary if you just cloned the repository
./pbackup --help # shows how to use the app
```

After installed, you can call it from anywhere, using:
```sh
pbackup --help # shows how to use the app
pbackup -v # checks the current version
```

If you installed the tool, you can use the pre-made backup scripts. Before using them, you need to set up the rclone configuration:
```sh
pbackup --config # you might have to run this command twice!
```
Follow the configuration steps, and create a remote
If you already have a remote configured in rclone, you can skip this step

After you have the tool installed to your path, and a remote configured in rclone (pbackup --config / rclone config), you can use the pre-made backup scripts:
```sh
# this script is premade for generating issabelpbx's backups (using our backup engine. it also works without our engine)
./scripts/backup-issabel.sh <remote> #i.e: ./scripts/backup-issabel.sh "mega:/backup-$(date +"%d-%m-%Y")"

# this script is premade for generating magnusbilling backups
./scripts/backup-magnus.sh <remote> #i.e: ./scripts/backup-magnus.sh "mega:/backup-$(date +"%d-%m-%Y")"
```
