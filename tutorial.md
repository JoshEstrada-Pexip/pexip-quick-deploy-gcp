# Deploy Pexip Infinity on GCP

<walkthrough-tutorial-duration duration="12"></walkthrough-tutorial-duration>

Deploy a single-region Pexip Infinity cluster on Google Cloud Platform (GCP) without manual SSH setup or complex networking.

### Understand Deployment Modes
Before starting, choose the mode that matches your testing goals:
* **Simple Mode (Self-Signed):** Boots a single Conferencing Node in `us-west1-b` with a self-signed TLS certificate and auto-generated credentials. (Zero prompts - best for a quick test of the GCE build).
* **Simple - Licensed/TLS Mode (Recommended):** Uses all the Simple defaults but automatically prompts for your Pexip trial/production license key and Cloudflare token to automatically provision browser-trusted Let's Encrypt certificates. (Best for testing TLS SIP calling immediately on completion).
* **Advanced Mode:** Full interactive control to customize sizing, regions, zone letters, custom passwords, CIDR access blocks, and node counts.

Click **Start** to begin.

## Step 1: Choose your GCP project

Create a new project to ensure that you have the permissions you need, or select an existing project in which you have the relevant permissions.

<walkthrough-project-setup></walkthrough-project-setup>

Select or create a GCP project with **billing enabled**. The project ID will be injected directly into the setup script.

## Step 2: Run the setup script

Click the command block below to paste it into the Cloud Shell terminal, then press **Enter**:

```bash
./scripts/setup.sh <walkthrough-project-id/>
```

> ⚠️ **Timeout Warning:** Terraform takes 8–12 minutes. Ensure your browser tab stays active and your computer does not sleep.

## Step 3: Automatic Base Configuration (Stage 2)

At the end of the deployment, the setup wizard will ask:
`Automatically run configuration sync now?` (Stage 2).

* **Choosing Yes (Recommended):** Automatically registers your licenses, Virtual Meeting Rooms (VMRs), Dial Plans, test users, and aliases using the pre-configured [pexip-config.yaml](file:///Users/joshestrada/Desktop/Pexip%20Projects/pexip-quick-deploy/pexip-config.yaml) file.
* **If you skipped it or want to customize it later:**
  1. Open the configuration file to inspect and customize your settings:
     ```bash
     nano pexip-config.yaml
     ```
  2. Sync your updates to the active Management Node by running:
     ```bash
     ./scripts/configure-platform.sh
     ```
* **Self-Signed/Simple Mode:** You can skip this configuration sync during setup as it requires a trial or production license key.

## Step 4: Access the Admin UI

When the setup script completes, it will output your credentials card:

```
Admin UI:   https://<manager-public-ip>/admin/
Username:   admin
Password:   (Generated or custom password)
```

1. Open the **Admin UI** link in your browser.
2. If you used **Simple Mode** (self-signed certs), bypass the browser warning by clicking **Advanced > Proceed**. (For **Licensed/TLS Mode**, the page will load securely without warnings).
3. Log in with your admin credentials.

## Step 5: Backup, Teardown, or Recovery

Keep these commands handy to manage, backup, or clean up your deployment:

### How to Download a Backup of your Configuration & State
If you chose not to download the backup at the end of the script, or if you need to fetch it later, run this command to package and download your configuration and active Terraform state:

```bash
python3 -c "import zipfile, os; files=['terraform/terraform.tfstate', 'terraform/terraform.tfvars', 'pexip-config.yaml', 'pexip-deployment-info.md']; zipf=zipfile.ZipFile('pexip-backup.zip', 'w', zipfile.ZIP_DEFLATED); [zipf.write(f) for f in files if os.path.exists(f)]; zipf.close()" && cloudshell download pexip-backup.zip
```

### If your session disconnected (How to get back)
If your Cloud Shell session closes, locate the active deployment directory:

```bash
for d in ~/cloudshell_open/pexip-quick-deploy*/; do [[ -f "$d/terraform/terraform.tfstate" ]] && echo "Active state found in: $d"; done
```

`cd` back to that folder to resume managing or destroying your deployment:
```bash
cd ~/cloudshell_open/pexip-quick-deploy-X
```

### How to Teardown/Clean Destroy
To safely destroy all resources and **automatically return/deactivate your licenses** to prevent locking them:
```bash
./scripts/destroy.sh
```

### How to Force Nuke
If your local state file is lost/corrupted and you need to force-wipe all GCP resources matching the stack naming convention:
```bash
./scripts/nuke.sh <walkthrough-project-id/>
```

<walkthrough-footnote>
Need a free trial license key? Request one at [pexip.com/start-trial](https://www.pexip.com/start-trial).
</walkthrough-footnote>

## Done!

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

Your deployment is complete. For multi-region enterprise layouts, refer to the full [terraform-google-pexip-infinity](https://github.com/Josh-E-S/terraform-google-pexip-infinity) module.
