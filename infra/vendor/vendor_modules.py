"""Fetch Retool's released Azure modules and apply this platform's patches.

Retool's blueprint repo publishes no licence, so its code is NOT stored in
this repo. This script downloads the exact release Terraform resolves for
`tryretool/self-hosted-blueprints/retool` 0.5.2 (git commit below), copies the
two modules we patch into infra/vendor/, and applies the three patches
documented in PATCHES.md. Every patch is anchored; if an anchor is missing
(upstream changed), it stops instead of patching blind.

    python3 infra/vendor/vendor_modules.py      # then: terraform -chdir=infra/platform init
"""
import io
import pathlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request

REPO = "tryretool/terraform-retool-self-hosted-blueprints"
COMMIT = "27e541f3faad993447362a1b9111816aa11a92b7"  # registry 0.5.2 -> x-terraform-get ref
MODULES = ["azure-vnet", "azure-user-ingress"]
HERE = pathlib.Path(__file__).resolve().parent
TAG = "PATCH (retool-azure-platform)"


def die(msg):
    sys.exit(f"vendor_modules: {msg}")


def insert_before_block_end(text, header, insertion):
    """Insert `insertion` just before the closing brace of the top-level block `header`."""
    start = text.find(header)
    if start < 0:
        die(f"anchor not found: {header}")
    end = text.find("\n}\n", start)
    if end < 0:
        die(f"no end for block: {header}")
    return text[:end] + "\n" + insertion.rstrip("\n") + text[end:]


def replace_once(text, old, new):
    if text.count(old) != 1:
        die(f"expected exactly one anchor: {old!r}")
    return text.replace(old, new)


def patch(root: pathlib.Path):
    # 1) azure-vnet: Key Vault inline access_policy vs separate access policies,
    #    and the Microsoft.Storage service endpoint Azure adds to the PG subnet.
    p = root / "azure-vnet" / "main.tf"
    t = p.read_text()
    t = insert_before_block_end(t, 'resource "azurerm_subnet" "postgres"', f"""
  # {TAG}: Azure adds a Microsoft.Storage service
  # endpoint when a Flexible Server joins this delegated subnet; without this,
  # every apply tries to remove it.
  lifecycle {{
    ignore_changes = [service_endpoint]
  }}""")
    t = insert_before_block_end(t, 'resource "azurerm_key_vault" "main"', f"""
  # {TAG}: access policies for workload identities are
  # added as separate azurerm_key_vault_access_policy resources (by
  # azure-retool-services and by this repo). Inline access_policy is
  # authoritative in azurerm, so without this every apply after the first
  # strips them and ESO loses Key Vault access.
  lifecycle {{
    ignore_changes = [access_policy]
  }}""")
    p.write_text(t)

    # 2) azure-user-ingress: one AGIC for several namespaces, ingress class fix,
    #    and ignore the tag AGIC writes on every sync.
    p = root / "azure-user-ingress" / "appgw.tf"
    t = p.read_text()
    t = replace_once(t, "      url_path_map,\n    ]", f"""      url_path_map,
      # {TAG}: AGIC stamps this tag on every sync;
      # without ignoring it each plan shows a tag-removal diff.
      tags["managed-by-k8s-ingress"],
    ]""")
    t = replace_once(t, "        ingressClass = local.ingress_class_name\n", f"""        # {TAG}: must equal controllerValue below.
        # AGIC 1.9.7 (pkg/environment/environment.go) overwrites its controller
        # name with INGRESS_CLASS when set, then requires
        # IngressClass.spec.controller == that name -- so "rtl-agic" vs
        # "azure/rtl-agic" silently matched no Ingress at all.
        ingressClass = "azure/${{local.ingress_class_name}}"
""")
    t = replace_once(t, "        watchNamespace = local.retool_namespace\n", f"""        # {TAG}: one AGIC/App Gateway serves several
        # Retool namespaces (prod + nonprod) instead of one gateway each.
        watchNamespace = join(",", concat([local.retool_namespace], var.extra_watch_namespaces))
""")
    p.write_text(t)

    p = root / "azure-user-ingress" / "variables.tf"
    p.write_text(p.read_text().rstrip("\n") + f"""

# {TAG}
variable "extra_watch_namespaces" {{
  type        = list(string)
  default     = []
  description = "Additional namespaces this AGIC reconciles Ingresses in, sharing the same Application Gateway (e.g. a nonprod Retool). Upstream assumes one gateway per deployment."
}}
""")


def main(dest=HERE):
    url = f"https://codeload.github.com/{REPO}/tar.gz/{COMMIT}"
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
        prefix = f"terraform-retool-self-hosted-blueprints-{COMMIT}/modules/"
        for m in MODULES:
            out = pathlib.Path(dest) / m
            shutil.rmtree(out, ignore_errors=True)
            for member in tf.getmembers():
                if member.isfile() and member.name.startswith(prefix + m + "/"):
                    rel = member.name[len(prefix):]
                    target = pathlib.Path(dest) / rel
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(tf.extractfile(member).read())
    patch(pathlib.Path(dest))
    for m in MODULES:
        subprocess.run(["terraform", "fmt", "-recursive", str(pathlib.Path(dest) / m)], check=True,
                       stdout=subprocess.DEVNULL)
    print(f"vendored {', '.join(MODULES)} from {REPO}@{COMMIT[:7]} with patches applied")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else HERE)
