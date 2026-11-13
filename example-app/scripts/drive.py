#!/usr/bin/env python3
"""Run example-app actions on an iOS Simulator and print the app's log.

Launches the installed app with `xcrun simctl launch`, passing every field
through the environment (SIMCTL_CHILD_*), lets it connect and run the named
actions in order, then prints the lines it wrote to stdout until it reports
`script done`. Install the app first with scripts/install.sh.

Examples:
  drive.py --token-file user-a.json --wallet gw-a address,balance
  drive.py --token-file user-a.json --wallet gw-a sendbtc recipient=tb1p... amount=50000
  drive.py --gateway http://127.0.0.1:8490 --network regtest \\
      --tip-url http://127.0.0.1:3003/blocks/tip/height \\
      --token-file local-a.json --wallet loc-a sync,assets

Fields passed as `name=value` reach the app too: recipient, amount, assetId.
A mnemonic the app prints on first run is written to --mnemonic-out (mode 0600)
and redacted from the output.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

BUNDLE_ID = "org.utexo.UTEXOExample"
MNEMONIC_PREFIX = "BACK THIS UP: "


def read_token(args: argparse.Namespace) -> str:
    if args.token_file:
        text = open(args.token_file).read().strip()
        # Accept either a bare token or the JSON that POST /v1/users returns.
        return json.loads(text)["token"] if text.startswith("{") else text
    token = os.environ.get("UTEXO_TOKEN")
    if not token:
        sys.exit("pass --token-file or set UTEXO_TOKEN")
    return token


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("actions", help="comma-separated actions, e.g. sync,balance")
    parser.add_argument("fields", nargs="*", help="name=value fields (recipient, amount, assetId)")
    gateway = os.environ.get("UTEXO_GATEWAY_URL")
    parser.add_argument("--gateway", default=gateway, required=gateway is None,
                        help="gateway base URL, e.g. https://your-gateway.example (default: $UTEXO_GATEWAY_URL)")
    parser.add_argument("--token-file", help="bare token, or the JSON returned by POST /v1/users")
    parser.add_argument("--wallet", required=True, help="wallet ID; one Keychain seed per ID and network")
    parser.add_argument("--network", help="signet (app default), regtest, testnet, mainnet")
    parser.add_argument("--tip-url", help="an HTTP /blocks/tip/height for the gateway's chain (tip.mjs on regtest)")
    parser.add_argument("--restore-from", help="file holding a mnemonic to restore on first connect")
    parser.add_argument("--mnemonic-out", help="where to save a newly generated mnemonic")
    parser.add_argument("--device", default="booted", help="simulator UDID or name (default: the booted one)")
    parser.add_argument("--timeout", type=int, default=420, help="seconds to wait for the script to finish")
    args = parser.parse_args()

    fields = {"gatewayUrl": args.gateway, "bearerToken": read_token(args), "walletId": args.wallet, "run": args.actions}
    if args.network:
        fields["network"] = args.network
    if args.tip_url:
        fields["tipUrl"] = args.tip_url
    if args.restore_from:
        fields["provisionedMnemonic"] = " ".join(open(args.restore_from).read().split())
    for field in args.fields:
        name, sep, value = field.partition("=")
        if not sep:
            sys.exit(f"expected name=value, got {field!r}")
        fields[name] = value

    # simctl hands SIMCTL_CHILD_<name> to the app as <name>, so the token and a
    # restore mnemonic never appear on a command line.
    env = dict(os.environ)
    env.update({f"SIMCTL_CHILD_{name}": value for name, value in fields.items()})

    with tempfile.TemporaryDirectory(prefix="utexo-drive-") as workdir:
        # The app writes its log lines here, including a newly generated
        # mnemonic, so the directory is private and removed afterwards.
        log_path = os.path.join(workdir, "stdout.log")
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", f"--stdout={log_path}",
                        args.device, BUNDLE_ID], check=True, env=env, stdout=subprocess.DEVNULL)

        deadline = time.time() + args.timeout
        lines: list[str] = []
        while True:
            if os.path.exists(log_path):
                with open(log_path, encoding="utf-8", errors="replace") as f:
                    lines = [l.rstrip("\r") for l in f.read().splitlines() if l.strip()]
            if "script done" in lines:
                break
            if time.time() > deadline:
                lines.append(f"[drive.py] no 'script done' after {args.timeout}s")
                break
            time.sleep(3)
        subprocess.run(["xcrun", "simctl", "terminate", args.device, BUNDLE_ID],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    for line in lines:
        if line.startswith(MNEMONIC_PREFIX):
            if args.mnemonic_out:
                fd = os.open(args.mnemonic_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as f:
                    f.write(line[len(MNEMONIC_PREFIX):])
                line = f"{MNEMONIC_PREFIX}[saved to {args.mnemonic_out}]"
            else:
                line = f"{MNEMONIC_PREFIX}[redacted; pass --mnemonic-out to keep it]"
        print(line)


if __name__ == "__main__":
    main()
