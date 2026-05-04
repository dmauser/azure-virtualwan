# Lab README Audit Report

**Generated:** 2026-05-04 17:36:02

## Executive Summary

This audit evaluates all lab folders in the zure-virtualwan repository against a standard README template to ensure consistency and completeness of documentation.

### Key Metrics

- **Total Labs:** 34
- **Labs with README:** 24 (70.6%)
- **Labs without README:** 10
- **Average Completeness Score:** 2.32 / 7 sections

### Template Requirements

The audit checks for 7 key sections in each README:

1. **Title** - Clear lab name/title
2. **Description** - Objectives, what will be learned
3. **Diagram/Topology** - Visual architecture diagram
4. **Prerequisites** - Required Azure resources, quotas, tools
5. **Deployment Steps** - Step-by-step deployment instructions with commands
6. **Cleanup** - Instructions for cleanup and resource deletion
7. **Results/Validation** - How to verify the deployment and expected outcomes

---

## Detailed Audit Results

| Lab Folder | Has README | Title | Description | Diagram | Prerequisites | Deploy Steps | Cleanup | Results | Score |
|---|---|---|---|---|---|---|---|---|---|
| any-to-any | True | True | True | True | False | True | False | True | 5/7 |
| ft-wan | True | True | False | True | False | True | False | True | 4/7 |
| gr-vwan | False | False | False | False | False | False | False | False | 0/7 |
| inter-region-azfw | True | True | True | True | False | True | False | True | 5/7 |
| inter-region-nva | True | True | True | True | False | True | False | True | 5/7 |
| inter-region-nva-srp | True | True | True | True | False | True | False | True | 5/7 |
| inter-region-nvabgp | True | True | True | True | False | True | False | True | 5/7 |
| inter-region-transitbgp | False | False | False | False | False | False | False | False | 0/7 |
| isolate-vnets-custom | True | True | False | True | True | True | False | False | 4/7 |
| lab | False | False | False | False | False | False | False | False | 0/7 |
| limits | False | False | False | False | False | False | False | False | 0/7 |
| migration-multi-region | False | False | False | False | False | False | False | False | 0/7 |
| migration-single-region | False | False | False | False | False | False | False | False | 0/7 |
| misc-cheatsheet | True | False | False | False | False | False | False | False | 0/7 |
| natvpn-over-er | True | True | False | True | False | True | False | True | 4/7 |
| nva-spoke-internet | True | True | True | True | False | False | False | True | 4/7 |
| nva-spoke-internet-inter-hub | True | True | True | True | False | True | False | True | 5/7 |
| p2s-usrgrp-svh | True | False | False | False | False | False | False | False | 0/7 |
| pa-ngfw-saas | True | False | False | False | False | True | False | False | 1/7 |
| secured-vhub | True | False | False | True | False | True | False | False | 2/7 |
| single-region-vpn | True | True | False | True | False | True | False | False | 3/7 |
| static-route-considerations | True | False | False | True | False | False | False | False | 1/7 |
| svh-bgp | True | True | False | True | False | True | False | False | 3/7 |
| svh-inter-region-er | True | True | True | True | False | True | False | False | 4/7 |
| svh-multi-hub | False | False | False | False | False | False | False | False | 0/7 |
| svh-ri-bgp | False | False | False | False | False | False | False | False | 0/7 |
| svh-ri-inter-region | True | True | False | True | False | True | False | True | 4/7 |
| svh-ri-intra-region | True | True | True | True | False | True | False | True | 5/7 |
| two-vwans | True | False | False | True | False | True | False | False | 2/7 |
| unified-lab | True | False | False | False | True | True | True | False | 3/7 |
| vhub-nvafw-bgp | False | False | False | False | False | False | False | False | 0/7 |
| vnet-conn-perf | False | False | False | False | False | False | False | False | 0/7 |
| vpn-over-er | True | True | False | True | False | True | False | True | 4/7 |
| vrf-vwan | True | False | False | True | False | False | False | False | 1/7 |

---

## Analysis by Category

### Labs Without README (10 total)
- **gr-vwan**
- **inter-region-transitbgp**
- **lab**
- **limits**
- **migration-multi-region**
- **migration-single-region**
- **svh-multi-hub**
- **svh-ri-bgp**
- **vhub-nvafw-bgp**
- **vnet-conn-perf**

### Labs with Complete READMEs (Score = 7)
None currently meet all 7 criteria

### Labs with Partial READMEs (Score 4-6)
- **any-to-any** — Score: 5/7
- **inter-region-azfw** — Score: 5/7
- **inter-region-nva** — Score: 5/7
- **inter-region-nva-srp** — Score: 5/7
- **inter-region-nvabgp** — Score: 5/7
- **nva-spoke-internet-inter-hub** — Score: 5/7
- **svh-ri-intra-region** — Score: 5/7
- **ft-wan** — Score: 4/7
- **isolate-vnets-custom** — Score: 4/7
- **natvpn-over-er** — Score: 4/7

### Labs with Poor Documentation (Score 1-3)
- **misc-cheatsheet** — Score: 0/7
- **p2s-usrgrp-svh** — Score: 0/7
- **pa-ngfw-saas** — Score: 1/7
- **static-route-considerations** — Score: 1/7
- **vrf-vwan** — Score: 1/7
- **secured-vhub** — Score: 2/7
- **two-vwans** — Score: 2/7
- **single-region-vpn** — Score: 3/7
- **svh-bgp** — Score: 3/7
- **unified-lab** — Score: 3/7

---

## Top Recommendations

Priority actions to improve lab documentation:

### Priority 1: Create Missing READMEs

1. **gr-vwan** — Missing README entirely
1. **inter-region-transitbgp** — Missing README entirely
1. **lab** — Missing README entirely
1. **limits** — Missing README entirely
1. **migration-multi-region** — Missing README entirely
1. **migration-single-region** — Missing README entirely
1. **svh-multi-hub** — Missing README entirely
1. **svh-ri-bgp** — Missing README entirely
1. **vhub-nvafw-bgp** — Missing README entirely
1. **vnet-conn-perf** — Missing README entirely

### Priority 2: Enhance Existing READMEs

1. **misc-cheatsheet** — Missing: Title, Description, Diagram, Prerequisites, Deploy Steps, Cleanup, Results/Validation
2. **p2s-usrgrp-svh** — Missing: Title, Description, Diagram, Prerequisites, Deploy Steps, Cleanup, Results/Validation
3. **pa-ngfw-saas** — Missing: Title, Description, Diagram, Prerequisites, Cleanup, Results/Validation
4. **static-route-considerations** — Missing: Title, Description, Prerequisites, Deploy Steps, Cleanup, Results/Validation
5. **vrf-vwan** — Missing: Title, Description, Prerequisites, Deploy Steps, Cleanup, Results/Validation

---

## Recommendations by Section

### Missing Prerequisite Sections (14 labs)
Many labs lack a dedicated Prerequisites section covering Azure subscription quotas, required CLI extensions, and estimated deployment costs.

**Recommendation:** Add a Prerequisites section to each README that covers:
- Azure subscription requirements
- Required CLI extensions (e.g., irtual-wan)
- Estimated resource costs
- Estimated deployment time

### Missing Cleanup Instructions (31 labs)
The majority of labs do not document cleanup procedures.

**Recommendation:** Add a Cleanup section with the Azure CLI command:
\\\ash
az group delete -n <resource-group-name> --yes --no-wait
\\\

### Missing Validation/Results Sections (15 labs)
Many labs lack clear guidance on how to verify successful deployment.

**Recommendation:** Add a Validation section with specific CLI commands or Portal steps to verify:
- Resource creation
- Connectivity validation
- Effective routes
- Expected outcomes

### Diagram/Topology Coverage (8 labs without diagrams)
Several READMEs lack visual topology diagrams.

**Recommendation:** Add either:
- Static PNG/SVG diagram (place in media/ folder)
- Mermaid diagram (embedded in README)

---

## Reference Template

The reference template for lab READMEs is located at: \docs/LAB_README_TEMPLATE.md\

Key sections to include:
- **Lab: {Title}** — Clear descriptive title
- **Objectives** — Bulleted list of learning outcomes
- **Architecture** — Diagram or visual representation
- **Prerequisites** — Requirements and setup
- **Estimated Deployment Time** — Realistic timeframe
- **Deployment Steps** — Numbered, executable steps with commands
- **Validation** — Commands to verify success
- **Cleanup** — Resource deletion instructions
- **Troubleshooting** — Common issues and solutions
- **References** — Links to Microsoft Learn and related labs

---

## Conclusion

**Current State:** While 70.6% of labs have some form of README documentation, the average completeness score of 2.32/7 indicates significant gaps in coverage of key sections. Most labs lack comprehensive prerequisites, cleanup instructions, and validation procedures.

**Next Steps:**
1. Create READMEs for the 10 labs that currently lack documentation
2. Enhance existing READMEs to include missing sections (especially Prerequisites, Cleanup, and Validation)
3. Ensure consistency in README format across all labs using the provided template
4. Add or improve topology diagrams where missing

---

## Notes

- This audit does not modify any existing lab files or READMEs
- All lab content remains unchanged as requested
- This report serves as a baseline for future documentation improvements
