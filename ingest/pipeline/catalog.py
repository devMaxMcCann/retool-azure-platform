"""Where each source comes from and why it may be published. Written to
source_catalog on every schema run and shown on the dashboard's Sources tab.

Everything here is copied from data/publication-review.md (citations fetched
2026-10-07). Change that document first, then this.
"""
from __future__ import annotations

from pathlib import Path

_DOL = ("Federal work: 'may be used, reproduced and distributed without permission'",
        "https://www.dol.gov/general/aboutdol/copyright", "verified")
_ENTITY = "Rows whose name doesn't look like an organization (inc, llc, corp, ...) are dropped at ingest."

CATALOG = {
    "warn": ("Illinois DCEO (Illinois workNet WARN reports)",
             "https://www.illinoisworknet.com/LayoffRecovery/Pages/ArchivedWARNReports.aspx",
             "No licence published. Statutory public notices published by DCEO since 1999; "
             "the owner accepted publishing them on 2026-10-08.",
             "https://dceo.illinois.gov/workforcedevelopment/warn.html", "owner_decision", None,
             "Contact names/phones, raw records and event-cause text are not stored."),
    "geocode": ("US Census Bureau Geocoder", "https://geocoding.geo.census.gov/geocoder/",
                "No licence text on the geocoder page; relied on 17 U.S.C. 105 (US government work).",
                "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                "Only Illinois street addresses from WARN notices are sent."),
    "chicago_licenses": ("City of Chicago Data Portal (Business Licenses, Current Active)",
                         "https://data.cityofchicago.org/resource/uupf-x98q.json",
                         "City of Chicago terms of use; derivative applications must show the City's disclaimer.",
                         "https://www.chicago.gov/city/en/narr/foia/data_disclaimer.html", "verified",
                         "chicago_disclaimer.txt",
                         "Home Occupation, Peddler and Home Repair licences dropped. " + _ENTITY),
    "idfpr_licenses": ("Illinois IDFPR (Professional Licensing, business licences)",
                       "https://illinois-edp.data.socrata.com/resource/pzzh-kp68.json",
                       "Open Database License (ODbL) 1.0. Derived databases used publicly are offered under ODbL.",
                       "http://opendatacommons.org/licenses/odbl/1.0/", "verified",
                       "Contains information from the Illinois Department of Financial and Professional Regulation "
                       "business licence dataset, made available under the Open Database License (ODbL).",
                       "Only business='Y' licences. " + _ENTITY),
    "bls_series": ("US Bureau of Labor Statistics (JOLTS, LAUS)", "https://api.bls.gov/publicAPI/v2/",
                   "'Everything that we publish ... is in the public domain'",
                   "https://www.bls.gov/opub/copyright-information.htm", "verified",
                   "Source: U.S. Bureau of Labor Statistics.", None),
    "bls_qcew": ("US Bureau of Labor Statistics (QCEW, Cook County)", "https://data.bls.gov/cew/data/api/",
                 "'Everything that we publish ... is in the public domain'",
                 "https://www.bls.gov/opub/copyright-information.htm", "verified",
                 "Source: U.S. Bureau of Labor Statistics.", None),
    "dol_lca": ("US Department of Labor (LCA disclosure data, H-1B)",
                "https://www.dol.gov/agencies/eta/foreign-labor/performance", *_DOL, None,
                "Certified H-1B only, aggregated per employer. " + _ENTITY),
    "dol_perm": ("US Department of Labor (PERM disclosure data)",
                 "https://www.dol.gov/agencies/eta/foreign-labor/performance", *_DOL, None,
                 "Certified only, aggregated per employer. " + _ENTITY),
    "msha_violations": ("US Mine Safety and Health Administration (Violations)",
                        "https://arlweb.msha.gov/OpenGovernmentData/DataSets/Violations.zip", *_DOL, None,
                        "Aggregated per violator; controller names never read. " + _ENTITY),
    "sba_ppp": ("US Small Business Administration (PPP loans over $150k)", "https://data.sba.gov/dataset/ppp-foia",
                "Dataset licence: 'U.S. Government Works'", "https://data.sba.gov/dataset/ppp-foia", "verified", None,
                "Sole proprietors, self-employed, independent contractors and single-member LLCs dropped. " + _ENTITY),
    "osha_sir": ("US Occupational Safety and Health Administration (Severe Injury Reports)",
                 "https://www.osha.gov/severe-injury-reports", *_DOL, None,
                 "Injury narratives are never read or stored. " + _ENTITY),
}


def seed(conn) -> None:
    here = Path(__file__).parent / "attribution"
    for source, (publisher, url, licence, licence_url, status, attribution, filters) in CATALOG.items():
        if attribution and attribution.endswith(".txt"):
            attribution = (here / attribution).read_text().strip()
        conn.execute(
            """INSERT INTO source_catalog (source, publisher, url, licence, licence_url, licence_status,
                   attribution, filters) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)
               ON CONFLICT (source) DO UPDATE SET publisher=excluded.publisher, url=excluded.url,
                   licence=excluded.licence, licence_url=excluded.licence_url,
                   licence_status=excluded.licence_status, attribution=excluded.attribution,
                   filters=excluded.filters""",
            (source, publisher, url, licence, licence_url, status, attribution, filters))
