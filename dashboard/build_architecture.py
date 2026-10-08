"""Build architecture.svg from the official icons in ./icons.

Icons are embedded byte-for-byte as data URIs (never edited, recoloured or
cropped -- Microsoft's icon terms, Kubernetes/PostgreSQL guidelines), each next
to its product name. Brands without published logo permission (Cloudflare,
Retool, Infisical, Let's Encrypt, GitHub) are drawn as labelled boxes.

    python3 build_architecture.py            # writes architecture.svg
"""
import base64
import pathlib

HERE = pathlib.Path(__file__).parent
ICONS = HERE / "icons"


def icon(name, x, y, size=34):
    p = ICONS / name
    mime = "image/png" if p.suffix == ".png" else "image/svg+xml"
    data = base64.b64encode(p.read_bytes()).decode()
    return f'<image x="{x}" y="{y}" width="{size}" height="{size}" href="data:{mime};base64,{data}"/>'


def box(x, y, w, h, fill="#fff", stroke="#9aa5b1", dash=False, r=8, sw=1.2):
    d = ' stroke-dasharray="6 4"' if dash else ""
    return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{sw}"{d}/>'


def text(x, y, s, size=12, weight="normal", fill="#1f2933", anchor="start"):
    return (f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" '
            f'text-anchor="{anchor}">{s}</text>')


def arrow(points, color="#52606d", dash=False, label=None, lx=None, ly=None):
    """Orthogonal arrow through the given points, rounded joins, one arrowhead."""
    d = "M" + " L".join(f"{x},{y}" for x, y in points)
    dd = ' stroke-dasharray="5 4"' if dash else ""
    out = (f'<path d="{d}" fill="none" stroke="{color}" stroke-width="1.6" stroke-linejoin="round" '
           f'stroke-linecap="round" marker-end="url(#arrow)"{dd}/>')
    if label:
        out += text(lx, ly, label, 10, fill="#52606d")
    return out


def svc(x, y, w, h, icon_name, title, sub=None, stroke="#9aa5b1", fill="#fff", isize=30):
    parts = [box(x, y, w, h, fill=fill, stroke=stroke)]
    if icon_name:
        parts.append(icon(icon_name, x + 10, y + (h - isize) / 2, isize))
        tx = x + 10 + isize + 10
    else:
        tx = x + 12
    if sub:
        parts.append(text(tx, y + h / 2 - 3, title, 12, "bold"))
        parts.append(text(tx, y + h / 2 + 13, sub, 10, fill="#52606d"))
    else:
        parts.append(text(tx, y + h / 2 + 4, title, 12, "bold"))
    return "".join(parts)


def build():
    W, H = 1240, 670
    o = [f'<svg class="arch" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" role="img" '
         f'aria-labelledby="archTitle archDesc" font-family="Segoe UI, Helvetica, Arial, sans-serif">',
         '<title id="archTitle">Platform architecture</title>',
         '<desc id="archDesc">Visitors resolve maxmccann.us through Cloudflare. The write-up page is proxied by '
         'Cloudflare to GitHub Pages; retool.maxmccann.us is delegated to Azure DNS, so platform traffic reaches an '
         'Azure Application Gateway directly. AKS runs Retool prod and nonprod, a read-only dashboard, and one '
         'CronJob per public data feed, which egress through a NAT gateway to public publishers. Data lands in '
         'Azure Database for PostgreSQL; secrets flow from Key Vault through Infisical.</desc>',
         '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" '
         'orient="auto-start-reverse"><path d="M0,1 L9,5 L0,9 z" fill="#52606d"/></marker></defs>',
         f'<rect width="{W}" height="{H}" fill="#fff"/>']

    # ---------------- edge (left)
    o.append(box(20, 268, 100, 54, stroke="#52606d"))
    o.append(text(70, 292, "Visitors", 12, "bold", anchor="middle"))
    o.append(text(70, 308, "public web", 10, fill="#52606d", anchor="middle"))

    o.append(box(160, 60, 200, 520, fill="#fff7ef", stroke="#f38020", sw=1.5))
    o.append(text(260, 86, "Cloudflare", 15, "bold", "#c25a00", "middle"))
    o.append(text(260, 103, "maxmccann.us zone (Terraform)", 10, fill="#7b4a1d", anchor="middle"))
    o.append(svc(175, 125, 170, 64, None, "Proxy + TLS", "maxmccann.us", stroke="#f38020"))
    o.append(svc(175, 395, 170, 70, None, "NS delegation", "retool.maxmccann.us", stroke="#f38020"))
    o.append(text(187, 457, "DNS only, not proxied", 10, fill="#7b4a1d"))
    o.append(svc(175, 230, 170, 56, None, "GitHub Pages", "write-up page", stroke="#9aa5b1"))
    o.append(arrow([(120, 285), (140, 285), (140, 157), (173, 157)]))
    o.append(arrow([(260, 189), (260, 228)]))
    o.append(arrow([(120, 305), (140, 305), (140, 430), (173, 430)]))

    # ---------------- Azure boundary
    o.append(box(390, 20, 830, 600, fill="#f7fbff", stroke="#0078d4", sw=1.5, r=12))
    o.append(text(410, 46, "Microsoft Azure  ·  centralus  ·  all resources in Terraform", 13, "bold", "#0b4a8b"))

    o.append(svc(410, 400, 190, 64, "azure-dns-zone.svg", "Azure DNS", "retool.maxmccann.us zone", stroke="#0078d4"))
    o.append(arrow([(345, 430), (408, 430)]))
    o.append(svc(410, 250, 190, 70, "azure-application-gateway.svg", "Application Gateway",
                 "Let's Encrypt TLS (DNS-01)", stroke="#0078d4"))
    o.append(arrow([(505, 400), (505, 322)], dash=True, label="resolves to", lx=512, ly=366))

    # VNet
    o.append(box(630, 60, 570, 545, fill="#ffffff", stroke="#0078d4", dash=True, r=10))
    o.append(icon("azure-virtual-network.svg", 642, 68, 22))
    o.append(text(670, 84, "Virtual network (private subnets)", 11, "bold", "#0b4a8b"))

    # AKS
    o.append(box(645, 100, 300, 490, fill="#f0f5fb", stroke="#326ce5", sw=1.4))
    o.append(icon("azure-kubernetes-service.svg", 657, 108, 26))
    o.append(text(690, 126, "AKS  (Pod Security: restricted)", 12, "bold", "#1d3f8a"))
    rows = [
        (145, "k8s-deploy.svg", "Retool prod", "namespace retool"),
        (210, "k8s-deploy.svg", "Retool nonprod", "upgrade lane"),
        (275, "k8s-deploy.svg", "Read-only dashboard", "demo.retool.maxmccann.us"),
        (340, "k8s-cronjob.svg", "Ingestion CronJobs", "one pod per public feed"),
        (405, "k8s-cronjob.svg", "Analytics build", "one transaction, daily"),
        (470, "k8s-secret.svg", "Infisical (private)", "per-namespace identities"),
    ]
    for y, ic, t, s in rows:
        o.append(svc(660, y, 270, 56, ic, t, s, stroke="#326ce5"))
    o.append(svc(660, 535, 270, 44, "k8s-ing.svg", "AGIC ingress controller", None, stroke="#326ce5", isize=26))

    # gateway -> apps
    for y in (173, 238, 303):
        o.append(arrow([(600, 285), (628, 285), (628, y), (658, y)]))

    # data + platform services (right)
    o.append(svc(970, 110, 215, 70, "azure-database-postgresql.svg", "PostgreSQL (Retool)",
                 "prod, nonprod, Infisical", stroke="#0078d4"))
    o.append(svc(970, 215, 215, 96, "azure-database-postgresql.svg", "PostgreSQL (public data)",
                 "ingest: raw, loaders only", stroke="#1a6b2a"))
    o.append(text(1020, 296, "analytics: published, read-only", 10, fill="#52606d"))
    o.append(icon("postgresql-slonik.png", 1150, 222, 26))
    o.append(svc(970, 345, 215, 60, "azure-key-vault.svg", "Key Vault", "root of trust", stroke="#8a5a00"))
    o.append(svc(970, 435, 215, 60, "azure-container-registry.svg", "Container Registry", "pinned image tags",
                 stroke="#0078d4"))
    o.append(svc(970, 525, 215, 60, "azure-nat-gateway.svg", "NAT Gateway", "single egress IP", stroke="#0078d4"))

    o.append(arrow([(930, 173), (950, 173), (950, 145), (968, 145)]))  # retool -> retool PG
    o.append(arrow([(930, 368), (960, 368), (960, 285), (968, 285)]))  # ingest -> data PG (writes)
    o.append(arrow([(930, 303), (944, 303), (944, 245), (968, 245)]))  # dashboard -> data PG (read-only)
    o.append(arrow([(968, 375), (945, 375), (945, 498), (932, 498)], color="#8a5a00"))  # KV -> Infisical
    o.append(arrow([(1078, 495), (1078, 523)], dash=True))           # images
    o.append(arrow([(1185, 555), (1212, 555), (1212, 635), (80, 635), (80, 606)], dash=True))

    # public sources (bottom-left, outside Azure)
    o.append(box(20, 540, 120, 64, fill="#f6fff6", stroke="#1a6b2a"))
    o.append(text(80, 562, "Public data", 12, "bold", anchor="middle"))
    o.append(text(80, 577, "publishers", 12, "bold", anchor="middle"))
    o.append(text(80, 594, "IRS, SEC, DOL, ...", 10, fill="#52606d", anchor="middle"))
    o.append(text(400, 655, "ingestion egress: honest User-Agent, robots.txt honoured, 401/403/429 never retried", 10,
                  fill="#52606d"))
    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    (HERE / "architecture.svg").write_text(build())
    print("wrote architecture.svg")
