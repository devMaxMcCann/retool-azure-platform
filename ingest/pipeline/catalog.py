"""Where each source comes from and why it may be published. Written to
source_catalog on every schema run and shown on the dashboard's Sources tab.

Everything here is copied from data/publication-review.md (citations fetched
2026-10-07). Change that document first, then this.
"""
from __future__ import annotations

from pathlib import Path

_DOL = ("Federal work: 'may be used, reproduced and distributed without permission'",
        "https://www.dol.gov/general/aboutdol/copyright", "verified")
_SEC_ORIGIN = ("US Securities and Exchange Commission (EDGAR)",
               "https://www.sec.gov/search-filings/edgar-search-assistance/accessing-edgar-data",
               "No explicit license; EDGAR access policy says anyone may access and download; only facts and "
               "metadata are copied.",
               "https://www.sec.gov/search-filings/edgar-search-assistance/accessing-edgar-data", "unverified")
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
    # ---- company-keyed federal sources: only exact normalized-name matches to
    # a WARN filer are stored (tables.yaml row filter: demo_public_companies).
    "irs_eo_bmf": ("Internal Revenue Service (Exempt Organizations Business Master File)",
                   "https://www.irs.gov/pub/irs-soi/eo1.csv",
                   "No licence text on the EO BMF page; relied on 17 U.S.C. 105 (US government work).",
                   "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                   "Only organisations whose name exactly matches a WARN filer. 'In care of' names and street "
                   "addresses are never read."),
    "sec_edgar": (*_SEC_ORIGIN, None,
                  "Only registrants whose current EDGAR name exactly matches a WARN filer; EDGAR entities typed "
                  "'individual' are dropped. Filings: 8-K Item 2.05 and Form D metadata only, no filing text."),
    "sec_financials": (*_SEC_ORIGIN, None,
                       "XBRL annual revenue, net income and long-term debt, only for registrants matched by "
                       "sec_edgar."),
    "usaspending": ("US Treasury Bureau of the Fiscal Service (USAspending.gov)",
                    "https://api.usaspending.gov/api/v2/search/spending_by_award/",
                    "No license page found; US federal agency data (17 U.S.C. 105 basis).",
                    "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                    "Only awards whose recipient name exactly matches a WARN filer; newest 100 contracts and "
                    "100 grants per company."),
    "fdic_bankfind": ("Federal Deposit Insurance Corporation (BankFind API)", "https://api.fdic.gov/banks/institutions",
                      "No public-domain statement found on FDIC website-policies page; US federal agency "
                      "(17 U.S.C. 105 basis).", "https://www.fdic.gov/about/website-policies", "unverified", None,
                      "Only institutions whose name exactly matches a WARN filer."),
    "cms_care_compare": ("Centers for Medicare & Medicaid Services (Provider Data Catalog, Hospital General "
                         "Information)", "https://data.cms.gov/provider-data/dataset/xubh-q36u",
                         "No license page fetched (404); US federal agency (17 U.S.C. 105 basis).",
                         "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                         "Only hospitals whose facility name exactly matches a WARN filer."),
    "fmcsa_safer": ("U.S. DOT - FMCSA (SAFER)", "https://safer.fmcsa.dot.gov/query.asp",
                    "No license page fetched; US federal agency (17 U.S.C. 105 basis).",
                    "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                    "USDOT number and carrier name only, when exactly one carrier's name matches a WARN filer."),
    "cfpb_complaints": ("Consumer Financial Protection Bureau (Consumer Complaint Database API)",
                        "https://www.consumerfinance.gov/data-research/consumer-complaints/search/api/v1/",
                        "No reuse/license statement found; CFPB states personal info is not published; US federal "
                        "agency (17 U.S.C. 105 basis).", "https://www.consumerfinance.gov/complaint/data-use/",
                        "unverified", None,
                        "One complaint count per company whose CFPB company name exactly matches a WARN filer. "
                        "No complaint rows and no narratives are read or stored. Complaints are allegations."),
    "ftc_cases": ("Federal Trade Commission (Legal Library: cases and proceedings)",
                  "https://www.ftc.gov/legal-library/browse/cases-proceedings",
                  "No license page fetched (copyright page 404); US federal agency (17 U.S.C. 105 basis).",
                  "https://www.law.cornell.edu/uscode/text/17/105", "unverified", None,
                  "Single-party titles only (no ',', ' and ', '&', ';', 'et al'); the party must exactly match "
                  "a WARN filer."),
    "fed_enforcement": ("Board of Governors of the Federal Reserve System (enforcement action press releases)",
                        "https://www.federalreserve.gov/feeds/press_enforcement.xml",
                        "'information on Board's website is in the public domain' unless otherwise indicated",
                        "https://www.federalreserve.gov/disclaimer.htm", "verified", None,
                        "Releases whose title mentions former employees, individuals, prohibitions, officers, "
                        "directors or presidents are dropped; a named party must exactly match a WARN filer."),
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
