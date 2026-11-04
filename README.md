# TariTalk Node Tool

A one-click Minotari Mainnet full node for your VPS. Install, check, upgrade and uninstall from a simple menu.

- Install a Minotari Mainnet full node, with Tor, in one go
- Check status and logs, upgrade and uninstall cleanly
- Optionally make its Wallet Query public over HTTPS, with a free ZeroSSL certificate
- Optionally make its read-only Base Node gRPC public over HTTPS, for gRPC clients

**Supported systems**

| System | AMD64 (x86_64) | ARM64 (aarch64) |
|---|:---:|:---:|
| <img src="assets/debian.ico" width="16" height="16" alt=""> Debian 12 | yes | yes |
| <img src="assets/debian.ico" width="16" height="16" alt=""> Debian 13 | yes | yes |
| <img src="assets/ubuntu.png" width="16" height="16" alt=""> Ubuntu 24.04 | yes | yes |
| <img src="assets/ubuntu.png" width="16" height="16" alt=""> Ubuntu 26.04 | yes | yes |

## Requirements

A **clean** VPS, `root` access and a public IPv4 address.

On Ubuntu, run the following to ensure the `Universe` repository is enabled:

```bash
apt update
apt install -y software-properties-common
add-apt-repository -y universe
```

### Required inbound ports

Open these ports in your cloud provider's firewall or security group (for example, OCI Security Lists or NSGs) and in the server firewall, if enabled.

| Port | Used for | When needed |
|---|---|---|
| TCP 18189 | Minotari P2P | After installing the node |
| TCP 80 | Certificate issuance and renewal | Feature 5 or 6 |
| TCP 443 | Wallet Query or Base Node gRPC over HTTPS | Feature 5 or 6 |

## Download

```bash
apt update
apt install -y curl
repo=https://github.com/xt1085/taritalk-node-deploy
curl -LO "$repo/releases/latest/download/taritalk-node-deploy.tar.gz"
tar -xzf taritalk-node-deploy.tar.gz
cd taritalk-node-deploy
```

Or with Git:

```bash
apt update
apt install -y git
git clone https://github.com/xt1085/taritalk-node-deploy.git
cd taritalk-node-deploy
```

Then open the menu:

```bash
./deploy.sh
```

```text
1. Install node
2. Node status
3. Node logs
4. Upgrade node
5. Install Wallet Query
6. Install Base Node gRPC
7. Submit node to TariTalk Nodes
8. Uninstall all
0. Exit
```

## Usage

Each menu item can also be run directly as a command.

### Feature 1: Install node

```bash
./deploy.sh install
```

Asks for your public IPv4 address, then installs and starts the node. Afterwards, open inbound TCP port 18189 so other nodes can reach yours. The first sync takes a while.

#### Optional Parameters

```bash
--public-ip YOUR_PUBLIC_IP   Public IPv4 address
--version 6.0.1              Install a specific release
--yes                        Skip the confirmation
```

Example:

```bash
./deploy.sh install --public-ip YOUR_PUBLIC_IP --yes
```

### Feature 2: Node status

```bash
./deploy.sh status
```

Shows whether the node and Tor are running, and how far the sync has got.

### Feature 3: Node logs

```bash
./deploy.sh logs
```

#### Optional Parameters

```bash
--lines 200    Number of lines to show
--follow       Keep showing new lines (Ctrl+C to stop)
```

Example:

```bash
./deploy.sh logs --lines 200 --follow
```

### Feature 4: Upgrade node

```bash
./deploy.sh upgrade
```

Upgrades to the latest Minotari release. Blockchain data, node identity and configuration are kept.

#### Optional Parameters

```bash
--version 6.0.2   Upgrade to a specific release
--yes             Skip the confirmation
```

Example:

```bash
./deploy.sh upgrade --yes
```

### Feature 5: Install Wallet Query

```bash
./deploy.sh wallet-query
```

Wallet Query lets compatible wallets use your node to scan the blockchain and retrieve the data they need. This feature makes it available to wallets and websites at `https://your-domain`, like TariTalk's public Wallet Query nodes.

Nginx provides HTTPS with a free ZeroSSL certificate that renews automatically, while the node itself keeps listening on `127.0.0.1:9000` only.

#### Before you start

- Have a domain name whose DNS A record points to this server. No domain name? You can ask TariTalk for a free community subdomain (see nodes.taritalk.xyz).
- Open inbound TCP ports 80 and 443.
- Make sure the server does not already run another web server, since this feature uses ports 80 and 443.

Press Enter without typing anything at the domain prompt to cancel.

#### Optional Parameters

```bash
--domain wallet.example.com   Domain name
--email you@example.com       Email for the ZeroSSL account
--yes                         Skip the confirmation
```

Example:

```bash
./deploy.sh wallet-query --domain wallet.example.com --email you@example.com --yes
```

### Feature 6: Install Base Node gRPC

```bash
./deploy.sh grpc
```

Makes your node's Base Node gRPC available to wallets, explorers and other gRPC clients at `your-domain:443` (gRPC over HTTPS with HTTP/2). This is not a website or Wallet Query: it serves gRPC calls only.

#### Before you start

- Have a separate domain name whose DNS A record points to this server.
- Open inbound TCP ports 80 and 443.
- To use both Features 5 and 6, set up Feature 5 first; gRPC will be added beside it without interrupting it.
- If Feature 5 is not set up, make sure the server does not already run another web server, since this feature uses ports 80 and 443.

Only these read-only methods are allowed:

- `get_version`
- `get_sync_info`
- `get_sync_progress`
- `get_tip_info`
- `identify`
- `get_network_status`
- `get_network_state`
- `list_headers`

Every other method is refused by the node (`PERMISSION_DENIED`); second-layer methods and mining stay off.

During setup, the node restarts once. Its gRPC listens only on `127.0.0.1:18142`, while Nginx provides HTTPS with a free ZeroSSL certificate that renews automatically.

#### Optional Parameters

```bash
--domain grpc.example.com     Domain name
--email you@example.com       Email for the ZeroSSL account
--yes                         Skip the confirmation
```

Example:

```bash
./deploy.sh grpc --domain grpc.example.com --email you@example.com --yes
```

### Feature 7: Submit node to TariTalk Nodes

```bash
./deploy.sh submit
```

Submits the currently running Mainnet node to TariTalk Nodes to apply to join the **Tari Global Node Lighting Initiative**. This community-led initiative aims to discover and document independently operated public nodes around the world, make Tari's global network coverage more visible, and encourage participation from more regions and operators.

The tool first asks for an optional operator name; pressing Enter keeps the node anonymous, and a verified anonymous node is listed as **Community registered**. A name is shown with the node and nothing more: it creates no account, login or management token. The tool then shows all details that would be sent, including the name if you gave one and the public Wallet Query and Base Node gRPC URLs if this tool set them up, and asks for confirmation; pressing Enter cancels and sends nothing. After confirmation, the details are sent over HTTPS for manual verification by TariTalk. A submission is not automatically listed; only verified nodes may be added to the TariTalk Nodes map and directory. On success, the tool prints `Success: Node submitted to TariTalk Nodes.` with the submission ID, and saves that ID with the time to `submission-id.txt` in the tool's directory, next to `deploy.sh`; a later successful submission replaces it with the newest ID.

To reduce abuse, repeated submissions from the same internet address may be temporarily rate limited. If the tool reports HTTP 429, wait a minute and try again.

### Feature 8: Uninstall all

```bash
./deploy.sh uninstall
```

Removes everything this tool installed, after showing the plan and asking you to confirm once: the node with its data, identity, configuration, logs, service and system user; Tor, if this tool installed it; and, if set up with Features 5 or 6, Wallet Query, Base Node gRPC and the Nginx this tool installed for them, with their certificates, renewal timers and records. Afterwards a new node, Wallet Query and gRPC can be set up again.

Kept: common packages such as ca-certificates, curl, jq, openssl and unzip, every other package, and this tool's files, except the saved `submission-id.txt`, which is removed last. DNS, Cloudflare, firewalls and cloud security groups are not changed. If anything this tool would remove is not exactly as it left it (for example a changed Nginx configuration or an extra file), the uninstall refuses before changing anything and tells you what to handle by hand.

> **Warning:** Uninstall permanently deletes the node's blockchain data, identity, configuration and logs, and the certificates of Wallet Query and gRPC. There is no undo.

## Updating this tool

If you installed the tool with Git:

```bash
cd taritalk-node-deploy
git pull --ff-only
```

Updating these tool files does not restart or upgrade the running node. To upgrade Minotari, use Feature 4 or run `./deploy.sh upgrade`.

## Help

```bash
./deploy.sh --help
./deploy.sh <command> --help
```

## Security

The node's Wallet Query listens only on `127.0.0.1:9000` and cannot be reached from the internet, unless you set up Feature 5, which puts Nginx with HTTPS in front of it. Its gRPC is off unless you set up Feature 6, which turns it on for `127.0.0.1:18142` only, with read-only methods, and publishes it through Nginx.

## About

TariTalk Node Tool is a community project by TariTalk, run independently by community members. It is not affiliated with Tari, Tari Labs, the Tari Council or the official team, and it is not official Tari software.

## License

[MIT](LICENSE)
