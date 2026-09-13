# Datasets

Pipeline goal: GeoJSON/PMTiles with **hunting-relevant attributes** for the offline Land Info sheet (WMU, crown land use, park status, township/municipality names, etc.).

This file records **what** each layer is and where it came from.
[`sourcing.md`](sourcing.md) records **how** to find the next one and how to tell
whether it is right — which endpoints work, why a boundary is only half a layer
without the provision that governs it, and what `tools/gis/audit_overlays.py`
refuses to publish.

## Ontario (primary)

| Layer | Source | Notes |
|-------|--------|-------|
| Crown land parcels | [MNR unpatented land](https://data.ontario.ca/dataset/crown-land-ministry-unpatented-land) attributed with [CLUPA](https://www.ontario.ca/page/crown-land-use-policy-atlas) and measured against [OHN 500K Waterbody](https://geohub.lio.gov.on.ca/datasets/lio::ontario-hydro-network-ohn-waterbody) | 43,058 of the source's 62,719 parcel-level tenure polygons (`fetch_unpatented_on.py` + `build_crown_on.py`); sub-half-hectare allowances are excluded, see below. The overlay means Crown **tenure**, not permission to hunt. 4,288 parcels are lake or river bed and say so — see below |
| Leased & occupied Crown land | [Crown Land – MNR Non-Freehold Dispositions](https://geohub.lio.gov.on.ca/datasets/lio::crown-land-mnr-non-freehold-dispositions) (LIO) | 33,167 leases, land use permits and licences of occupation via `fetch_dispositions_on.py`. **Not a closure** — the Crown still owns it, but the holder may refuse entry. Easements excluded, see below |
| Policy documents | CLUPAPRO policy + permitted-use tables | `build_policies_on.py` writes one markdown file per policy id, including the official Hunting permitted-use row, plus a deep link to the live report |
| WMUs | Ontario MNRF open data | Wildlife Management Units |
| Seasons (ON) | [Ontario Hunting Regulations Summary](https://www.ontario.ca/document/ontario-hunting-regulations-summary) | `scrape_seasons_on.py` parses the open-season table in every species chapter into `data/on/seasons/YYYY.json`. 21 species, 150 WMUs. Migratory birds are federal and excluded |
| Provincial parks | [Provincial Park Regulated](https://data.ontario.ca/dataset/provincial-park-regulated) (LIO) + [O. Reg. 663/98](https://www.ontario.ca/laws/regulation/980663) Part 3 + [PPCRA](https://www.ontario.ca/laws/statute/06p12) s. 15 (2) | 347 regulated parks. LIO publishes the boundary; the **permission** comes from the regulation, since no Ontario GIS layer carries it. Algonquin also carries the one opening written into the Act rather than the regulation — see below |
| Conservation reserves | [Conservation Reserve Regulated](https://geohub.lio.gov.on.ca/datasets/lio::conservation-reserve-regulated) (LIO) + [PPCRA](https://www.ontario.ca/laws/statute/06p12) ss. 15 (3), 12 (3) | 306 regulated reserves via `fetch_conservation_reserve_on.py`. The **opposite** of a park: the Act permits hunting unless a regulation closes it — see below |
| Sunday gun hunting | [O. Reg. 665/98](https://www.ontario.ca/laws/regulation/980665) s. 66(1) + [O. Reg. 663/98](https://www.ontario.ca/laws/regulation/980663) Part 7, Schedule 1 + WMU boundary fabric | 193 scheduled southern jurisdictions (`build_sunday_gun_on.py`) plus a north-of-divide polygon and near-divide band derived from the WMU boundary fabric (`build_sunday_divide_on.py`). The WMU boundary traces the French and Mattawa rivers per O. Reg. 663/98 Part 6, so it IS the ministry's own digitisation of the divide |
| Municipal & county forests | [Agreement Forest Area](https://data.ontario.ca/en/dataset/agreement-forest-area) + [County of Renfrew forest guidance](https://www.countyofrenfrew.on.ca/living-here/outdoors/forests/) | 2,325 **parcel-level** tracts (~81.1k ha) via `fetch_agreement_forest_on.py`. This is the public land people hunt in southern Ontario, where there is almost no Crown land. Gaps between tracts are private |
| Crown game preserves | [Crown Game Preserve](https://data.ontario.ca/dataset/crown-game-preserves) (LIO) | 15 polygons via `fetch_game_preserve_on.py`. Hunting and trapping prohibited under **FWCA s. 9** regardless of underlying tenure |
| Conservation authority land | [CPCAD](https://www.canada.ca/en/environment-climate-change/services/national-wildlife-areas/protected-conserved-areas-database.html) (ECCC) | 409 properties across 28 authorities via `fetch_cpcad_on.py`. **Permit-only, not public.** Knowingly incomplete — see below |
| Wildlife areas & bird sanctuaries | CPCAD (ECCC) + [C.R.C. c. 1609](https://laws-lois.justice.gc.ca/eng/regulations/C.R.C.,_c._1609/) and [c. 1036](https://laws-lois.justice.gc.ca/eng/regulations/C.R.C.,_c._1036/) | 13 NWAs and 11 sanctuary polygons. ECCC draws the boundary; the prohibition comes from the regulation via `parse_federal_wildlife_regs.py` |
| Reserves | [Canada Lands Survey System](https://www.nrcan.gc.ca/maps-tools-publications/maps/canada-lands-survey-system) (NRCan) | 203 Ontario reserves via `fetch_first_nations_on.py`. **Permission required, not prohibited** — see below |
| Defence property | [DFRP](https://www.tbs-sct.canada.ca/dfrp-rbif/home-accueil-eng.aspx) (Treasury Board) | 140 Ontario National Defence properties, 51,309 ha, via `fetch_defence_land_on.py`. Closed to public hunting |
| Far North & community land use plans | [Land Use Plan Area, MNR](https://www.ontario.ca/page/land-use-planning-process-far-north) (LIO) | The Far North boundary plus 4 approved community plans (3.0M ha) via `fetch_land_use_plan_on.py`. Context, not tenure — see below |
| Geographic townships | LIO Geographic Township Improved | `fetch_townships_on.py`. A build input, not shipped: `build_sunday_gun_on.py` resolves the schedule's "Geographic Townships of" entries against it. Nothing can draw it, so it is not in the manifest and does not download |
| Municipalities | LIO MUNICLOW | Lower/single-tier bylaw jurisdiction |

**License:** Ontario [Open Government Licence](https://www.ontario.ca/page/open-government-licence-ontario),
except the two CPCAD-derived layers, which are [OGL–Canada](https://open.canada.ca/en/open-government-licence-canada).
Regulation text is reproduced from the Justice Laws and e-Laws consolidations and
is not the official version.

### Hunting in a provincial park is prohibited unless a schedule opens it

Under the FWCA, hunting in an Ontario provincial park is only permitted on the
lands scheduled in O. Reg. 663/98 Part 3. The park layer previously marked all
347 parks `hunting_allowed: false`, which was wrong in both directions: it told
people they could not hunt Rock Point or Darlington, and said nothing about the
parks that are open.

`parse_reg663_on.py` reads the consolidated regulation from the e-Laws v2 API
(`/laws/api/v2/legislation/en/doc-search/regulation/980663`; the public HTML page
is a JavaScript shell with no text in it) and records its currency date. Of 135
live schedules, **100 open a whole area and 35 open a surveyed part**. That split
decides what the app is allowed to claim:

| Schedule opens | `hunting_allowed` | Card says |
|----------------|-------------------|-----------|
| The whole park | `true` | Hunting listed as permitted |
| A surveyed part | `null` | Open in part of this park only |
| Park not scheduled | `false` | No hunting — park not opened |

A partial schedule is metes-and-bounds prose referring to plans deposited with
the Surveyor General — "designated as Parts 1, 2, 4 and 5 on a plan known as …".
Ontario does not publish those boundaries, so a park outline cannot answer for a
particular point inside it and the card says exactly that rather than resolving
it to yes or no.

Carve-outs are quoted verbatim, never summarised, because they are what decides
legality on the ground: Grundy Lake is open "excepting those parts thereof that
are posted with signs prohibiting hunting", and Chapleau-Nemegosenda and
Missinaibi are open except the part inside the Chapleau Crown game preserve,
which we already draw as its own layer.

Two things worth knowing about the join. It matches only on a park's full name,
so Bonnechere Provincial Park stays closed while Bonnechere River Provincial Park
is open — a stem match would have conflated them. And Schedules 4 and 7 describe
designated Crown lands rather than parks, so they bind to no park polygon and
those areas are still reported as closed; that is a known gap, recorded in the
layer metadata as `unbound_schedules`.

### One park is opened by the Act rather than by the regulation

O. Reg. 663/98 Part 3 is not the whole story. The Provincial Parks and
Conservation Reserves Act, 2006 s. 15 (2) permits hunting on the public lands in
the Geographic Townships of Bruton and Clyde that the 1960-61 extension added to
Algonquin, and it says so despite s. 15 (1). No schedule carries that, so a card
built only from the regulation quoted Schedule 42 — the McRae Addition in Eyre
Township — and stopped, which told a hunter standing in Bruton that the park was
closed to them.

`parse_ppcra_on.py` reads s. 15 and s. 12 (3) from the same e-Laws v2 API and
refuses to write a rule file if the subsections no longer contain the words that
carry the rule, so a renumbered or reworded Act fails the build rather than
handing the app a claim it would state as law. `fetch_wmu_parks_on.py` then
attaches the statutory opening to Algonquin only, by exact park name, and the
card shows both openings — the schedule and the Act — each quoted verbatim with
its own citation. Where the statute opens a park no schedule reaches, the basis
becomes `ppcra_s15_2_partial` and the verdict is the partial one rather than
"park not opened".

Both openings are described in words rather than published as boundaries, so the
outline still cannot say whether a given point is inside either one.

### A conservation reserve is the mirror image of a park

Under the same Act, s. 15 (3) reads: *"Hunting is permitted in conservation
reserves unless it is prohibited by regulation made under the Fish and Wildlife
Conservation Act, 1997."* Where s. 15 (1) closes a park unless a regulation opens
it, s. 15 (3) opens a reserve unless a regulation closes it. And s. 12 (3) adds
that hunting in a reserve "shall not be constrained by zoning", so a management
plan cannot narrow it either.

We carried no reserve boundaries at all. Our only route to the designation was
CLUPA, whose planning area stops short of southern Ontario, so every conservation
reserve down there read to us as undesignated Crown land. Comparing our card
against iHunter's at Conroys Marsh is what surfaced it: they named the reserve and
we said "General rules apply, no local policy".

`fetch_conservation_reserve_on.py` takes all 306 regulated reserves from LIO and
states `hunting_allowed: true` with a `ppcra_s15_3` basis — one of the few things
in the app entitled to the green badge, because a statute permits it outright
rather than a planning table listing it as a permitted use. The layer header
carries the two subsections verbatim once instead of on all 306 features. Only
regulated reserves qualify: a *recommended* reserve is not yet a conservation
reserve, so the fetcher skips anything whose status is not `Regulated
Conservation Reserve` rather than letting it inherit the permission.

The prohibition the subsection contemplates is a Crown game preserve, which we
draw as its own layer, and six reserves are overlapped by one. There the closure
leads the card. iHunter shows both the reserve's permission and the preserve's
prohibition at Conroys Marsh without resolving them.

### The tenure record covers lake beds, and the card used to describe them as dry ground

A tap in the middle of Round Lake returns a 2,625 ha Crown parcel, and the record
is right: a lake bed is unpatented Crown land. But the card there was word for
word the card on dry ground — "Crown land — Ministry unpatented", "General rules
apply, no local policy", and the paragraph about seasons, licences and discharge
by-laws. Nothing on it said water. Over Burns Lake, inside a General Use Area, we
went further and reported hunting as *listed as permitted* while iHunter retreated
to "Contact MNR". LIO layer 34 cannot fix this on its own: on that parcel every
descriptive field is null.

Dropping those parcels is not the fix. It would manufacture an exclusion the
province never made, and waterfowl hunting over Crown water is legal. So
`fetch_hydrography_on.py` pulls the 1:500,000 OHN waterbody generalisation at
build time — 55,000 polygons, 39 MB, **none of which ships** — and
`build_crown_on.py` measures each parcel against it. The distribution is strongly
bimodal: 32,118 of 42,713 parcels are under 10% water and 4,844 are over 90%,
with only a few hundred per decile in between, so the 90% threshold sits in a real
gap rather than on a judgement call. It flags Round Lake at 98% and Burns Lake at
96% and leaves the Madawaska Highlands at 2% and Conroys Marsh at 14% alone.

Only a boolean ships, which costs about 90 kB across the layer. That buys a fact
about the *parcel*, not about the tap: Round Lake's dry 2% is still ~50 ha, and a
site 240 m inland from the water's edge falls inside the same parcel and is
flagged. A per-point answer would need the hydrography in the pack, which the pack
budget will not take, so the note does what the parks layer already does for an
opening described in words — states what is known about the outline and says
plainly that it cannot place you inside it. The flag never changes the verdict and
never leads the card: water is not a closure.

### Conservation authority land is permit-only, from a source that is admittedly partial

This is the most dangerous class of land in southern Ontario. It looks public,
it often adjoins the municipal forest we already draw as open, and hunting it
without the authority's permit is trespass. Authorities charge a fee, several
allocate popular tracts by lottery, and some close properties to hunting
outright — Grand River runs online lotteries for Belwood and Conestogo, Upper
Thames charges $85 plus proof of insurance and patrols with Provincial Offences
Act officers, Niagara Peninsula bans coyote hunting on several tracts.

There is no consolidated provincial register of conservation authority property.
CPCAD filtered to Ontario conservation areas gives 409 polygons across 28 named
authorities, and that is the best free source available — but **it holds only
what each authority chose to report**. Grand River Conservation Authority is
absent entirely; Essex Region, Grey Sauble, Kawartha, Otonabee and Lakehead each
report a single property.

That incompleteness is the whole design constraint. The layer may only ever
*add* uncertainty: a polygon means "ask this authority", and the absence of one
means nothing at all. `hunting_allowed` is `null` with a `ca_permit` basis, the
metadata carries `coverage_incomplete`, and Land Info surfaces the caveat
specifically where the layer drew nothing — which is exactly where its silence
could be misread as permission. On a property it does cover, the caveat is
suppressed, because repeating it there would bury the instruction to get a
permit.

One thing deliberately *not* built: the [Conservation Authority Administrative
Area](https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/LIO_OPEN_DATA/LIO_Open03/MapServer/11)
layer (36 features). That is watershed *jurisdiction*, covering essentially all
of settled southern Ontario including private land. Rendering it as CA land
would be a serious error.

### Federal wildlife areas: the firearm prohibition is the part that catches people

ECCC's CPCAD supplies the boundaries; the prohibitions come from the regulations,
read by `parse_federal_wildlife_regs.py` from the Justice Laws XML consolidation
so the app quotes the law rather than quoting us.

**National Wildlife Areas.** The *Wildlife Area Regulations* s. 3(1)(b) and (c)
prohibit hunting and possessing equipment that could be used for hunting in any
wildlife area. Only Schedule I.1 can open one, under s. 3.1. In Ontario it opens
sport hunting of waterfowl in exactly two of the ten: **Big Creek** (item 9) and
**Long Point** (item 6), dogs off leash, half an hour before sunrise to half an
hour after sunset, non-toxic shot only. Even those two cannot be reported as
simply open — the regulation says "in designated areas", the Minister designates
them under s. 3.2, and those designations are not published as geometry. So they
carry `hunting_allowed: null` with `hunting_extent: part`, the same treatment as
a partially-scheduled provincial park, and the card says the outline cannot place
a point inside the open area.

Three Ontario NWAs may not be **entered** without a federal permit, under
s. 3.3(1): Eleanor Island (b), Wellers Bay (c) and Scotch Bonnet Island (d).
Wellers Bay is worth singling out — a former DND air weapons range with
unexploded ordnance, which a hunter might well assume is open because it is a
waterfowl NWA on Lake Ontario.

**Migratory Bird Sanctuaries.** s. 3(2)(a) prohibits hunting migratory birds,
which on its own would leave deer hunting untouched. s. 4(1) then separately
prohibits possessing **any firearm or any hunting appliance** in a sanctuary.
Together those close a sanctuary to hunting anything by any means, including
walking through with a slung rifle, and it is the second prohibition the app has
to lead with because it is the one nobody expects.

Names are matched by stem, not fuzzily: ECCC writes "Migratory Bird Sanctuary"
where the regulation writes "Bird Sanctuary", splits areas into named units
("Big Creek NWA – Hahn Unit"), and differs on possessives (St. Joseph Island vs
St. Joseph's Island, Becketts vs Beckett Creek). All 24 polygons currently bind
to a scheduled area. Any that stopped binding would be reported as an unverified
closure — treat as closed, rules unconfirmed — rather than silently asserted or
dropped.

Two source notes. Ontario's own LIO "National Wildlife Area" layer
(`LIO_Open03/9`) has only 5 features and three of them are actually sanctuaries;
it is stale and mislabelled, and CPCAD is used instead. And Hannah Bay moved into
a shared "Ontario and Nunavut" schedule part in SOR/2025-99, where it is the only
item and therefore unnumbered — the parser has a documented fallback for that.

### Reserve land: permission required is not the same answer as prohibited

Reserve land is federal land held for the use and benefit of a First Nation. An
Ontario hunting licence conveys no right of access to it — the province has no
authority to grant that — so the layer reports **permission of the First Nation
required** and never "no hunting". Conflating the two would be wrong on the
facts and would put a wildlife-law framing on what is a question of access.

The layer is deliberately silent on two things. It says nothing about the
harvesting rights of members, and nothing about Aboriginal or treaty rights
under s. 35 of the *Constitution Act, 1982*. It answers one question: whether a
licensed hunter looking for somewhere to hunt may treat this ground as
available. They may not, without asking.

Source is NRCan's Canada Lands Survey System, which is the survey-derived
federal boundary and states accuracy per feature — 53 reserves are surveyed
better than 2 m, 120 better than 100 m, and one is looser than 100 m and drawn
as approximate. Ontario's own LIO Indian Reserve layer holds 246 polygons
against CLSS's 203, the difference being multipart reserves recorded separately
rather than extra land. The federal survey is the authority for a federal
boundary, so CLSS wins.

### Defence property is closed, but "closed" needs a caveat

National Defence holds 140 Ontario properties totalling 51,309 ha, and three of
them are big enough to matter to a hunter: Petawawa at 24,229 ha, Borden at
8,111 and Meaford at 7,685. They sit in bush, they are unfenced for most of
their perimeter, and nothing in the app said anything about them before.

A flat "no hunting" would be slightly wrong. Some bases run their own controlled
hunts that civilians can apply for — with a mandatory safety briefing, shooting
qualification and daily registration at Range Control. But which bases, in which
areas, in which seasons is not published as data anywhere, and it changes year
to year. So the card says the ground is closed to public hunting unless you are
in a hunt the base itself administers, and links to the property's own DFRP
record rather than naming programmes a shipped pack cannot keep current.

Armouries and urban operations facilities are kept even though nobody would try
to hunt them. They are small, and dropping a closed property because we assume
nobody wants it is the wrong instinct here.

### The atlas link carries the coordinate, and why we trust it

Where a parcel has a policy id the app opens that policy's own report. Where it
has none, the link centres the atlas on the tapped point:

```
.../CLUPA/index.html?viewer=CLUPA.CLUPA&locale=en-CA&center=<lon>,<lat>,4326&scale=9027.977411
```

Longitude leads — the viewer reads the pair as an ArcGIS `x,y` point — and the
trailing `4326` is the spatial reference it reprojects from. `scale` is a
denominator that the viewer snaps to its nearest cached level.

This was verified against shipped code, not just vendor documentation, because
the failure mode is silent and a link that quietly opens the wrong place is
worse than one that admits it opens the province. Four things were checked
directly:

- `Resources/Compiled/Map.js` contains `CenterSharingLinkProvider`, whose
  `_applyCenter` builds `new esri.geometry.Point(parseFloat(e[0]), parseFloat(e[1]))`,
  sets the spatial reference from a third element if present, and calls
  `panToPointWithPriority`. That is the axis order and the WKID handling, read
  off the code rather than inferred from a doc example.
- CLUPA's own served viewer config registers that provider, with no `name`
  override, so the parameter really is spelled `center` on this site.
- The viewer is Geocortex Viewer for HTML5 `gvh4.14.5`, and the vendor's 4.14
  [launch URL reference](https://docs.vertigisstudio.com/essentials/gvh/4.14/admin-help/Content/gvh/admin/viewer-urls.htm)
  documents `center=x,y,wkid` for exactly that version.
- The map is Web Mercator (WKID 102100) only, and the projection helper
  short-circuits 4326 ↔ Web Mercator to a client-side call, so a WGS84
  coordinate needs no geometry service and no conversion on our side.

Two caveats are worth carrying. A malformed value produces only a console
warning and leaves the map at the province, with nothing on screen to say so —
which is why the dialog still shows the coordinates and offers to copy them.
And the parameter names come from configuration rather than code, so if MNRF
republishes CLUPA with a different provider list the links will break silently.
Re-check `Desktop.json.js` if they ever seem to stop working.

Because the support is per-viewer, it is opted into per province:
`policy_atlas_accepts_centre` in the manifest, set only for Ontario. A province
whose atlas has not been checked gets the plain URL.

The viewer has no marker or pushpin parameter in this version, so the atlas
centres on the point but does not pin it.

### The Far North: no policy report is not the same as no policy

Tap a Crown parcel above the Far North line and there is usually no policy
report, because the Crown Land Use Policy Atlas thins out up there. The card
used to read that as "no land use policy covers this parcel", which asserts an
absence of policy when what we actually have is an absence of atlas.

CLUPA is sparse in the Far North rather than missing, and the difference is
worth measuring rather than assuming. Counting CLUPA polygons by bounding box:

| Area | CLUPA polygons |
|------|----------------|
| Thunder Bay (48.4°N, control) | 717 |
| Sudbury (46.5°N, control) | 234 |
| Big Trout Lake (53.7°N) | 11 |
| Pikangikum / Whitefeather (51.8°N) | 4 |
| Attawapiskat (52.9°N) | 0 |
| Fort Severn (55.9°N) | 0 |

So north of the line the dialog says the atlas has probably never reached this
ground, and where one of the four approved community based land use plans covers
the point it names the plan and links the document. Those plans are direction for
how Crown land is planned and managed, **not** hunting regulations, and the
wording says so: seasons and WMU rules still decide whether you may hunt.

The four plans outside the Far North — Ontario's Living Legacy, Madawaska
Highlands, Cochrane District and Temagami — are deliberately excluded. CLUPA
covers those areas densely, so the parcel already has its own policy report and
a second competing link would only muddy it.

The layer is drawn at 1% opacity and always queryable. Its outline is simplified
to roughly 200 m, which is fine because nothing legal turns on it: it selects
which explanation the card shows.

### Sunday gun hunting is a prohibition almost everywhere in the south

Sunday gun hunting is permitted everywhere north of the French and Mattawa
rivers (O. Reg. 665/98, s. 66(1) — the prohibition applies only south of the
rivers). South of them it is permitted **only** in the 193 jurisdictions
scheduled in O. Reg. 663/98 Part 7, so a southern municipality absent from that
schedule is a prohibition rather than a gap.

The north-of-divide polygon is derived from the WMU boundary fabric: the shared
boundary between northern and southern WMUs follows the French and Mattawa
rivers as described in O. Reg. 663/98 Part 6, including the Lake Nipissing
crossing. This is the ministry's own digitisation of the regulatory line.
A 500 m near-divide band (each side of the line) carries `boundary_accuracy:
"approximate"` and `near_divide: true` so the card can warn that any point
that close to the river is genuinely uncertain — the regulation means the
actual river, not a digitised centreline. Within the band the card refuses to
lead with the word permitted, because the wrong bank in an unlisted township is
an offence and this layer does not know which bank it is looking at.

The band is cut out of the north polygon, and the build simplifies **before**
cutting rather than after. Simplifying the two pieces separately afterwards moves
their shared edge by different amounts — the coast tolerance on one side, the
divide tolerance on the other — and they stop meeting: that left 1,015 slivers
along the divide covered by neither feature, each one a false "not permitted" in
country where hunting is legal, since the card reads a missing feature as a
prohibition. For the same reason the coast tolerance has to stay smaller than the
band's half-width, and the build refuses to run if it is not: ground dragged
across the line by simplification is then still inside the band, and is reported
as unknown rather than as one side or the other.

`build_sunday_divide_on.py` runs before `build_sunday_gun_on.py`, which appends
its output and now fails rather than warns when it is missing. The layer builds
perfectly well without it and looks complete, while everything north of the
rivers has quietly lost its answer.

The schedule names three kinds of area and each resolves differently: lower and
single tier municipalities, whole upper-tier counties, and grouped geographic
survey townships, which are not municipalities at all. The schedule also still
uses pre-restructuring names, so a small documented alias table maps
Galway-Cavendish and Harvey to Trent Lakes (amalgamated 2016),
Cavan-Millbrook-North Monaghan to Cavan Monaghan (renamed 2006), and the
regulation's spelling "Henvy" to the survey fabric's "Henvey". Every alias is a
rename of the same area; none is a judgement about which areas are scheduled. All
193 entries currently resolve, and `build_sunday_gun_on.py` records any that do
not in `unmatched_entries`.

Because only the permitted side is drawn, the absence of a polygon south of the
rivers is a prohibition, not a gap. North of the rivers, the north-of-divide
polygon answers the question that previously required a hedge.

### Crown game preserves override tenure

The Crown tenure fabric describes who owns the land, not whether it is closed. Inside a Crown game preserve, [FWCA s. 9](https://www.ontario.ca/laws/statute/97f41) prohibits hunting, trapping and possessing wildlife, and s. 9(2) prohibits even possessing a firearm or trap unless you live on private land inside the preserve. Without this layer the tenure attributes actively mislead — sampling 250 random interior points of each preserve against `crown_land`:

| Preserve | Reads "hunting permitted" | Reads unknown | Reads "not permitted" |
|----------|--------------------------|---------------|----------------------|
| Chapleau | 95 | 124 | 14 |
| Peterborough | 69 | 6 | 51 |
| Nipissing | 4 | 233 | 0 |

So the layer is drawn *above* the tenure layers, and stays queryable with its toggle off — hiding the outline must not hide the reason you cannot hunt.

Three of the 15 (Conestogo, Dumfries, Puslinch) carry `REGULATED_IND = No` in the provincial record. They are kept and flagged `fwca_s9_unconfirmed` rather than dropped or silently asserted: failing to warn risks a charge, while an over-warning costs a phone call. Two exemptions are not modelled because the dataset cannot express them — s. 102(1) for residents on their own land inside a preserve, and s. 102.1, which exempts one lot of the Himsworth preserve outright.

### A lease on Crown land is not a closure, and not nothing either

Crown tenure says the province owns the ground. It does not say who is living on
it. Ontario grants leases, land use permits and licences of occupation over its
own land — hunt camps, cottages, docks, mining claims — and under [Trespass to
Property Act s. 2](https://www.ontario.ca/laws/statute/90t21) the occupier of a
described area may prohibit entry to it. No wildlife law closes this ground and
no season changes on it, so `hunting_allowed` is `conditional` rather than
`false`, and the badge reads "Occupied — the holder may refuse entry" instead of
borrowing a closure's wording or its colour.

This is the layer that answers the largest honest gap in `crown_land`. Where a
parcel carries no land use policy the app can only fall back on the province's
general rule, and a leased hunt camp inside such a parcel was drawn as ordinary
open Crown land. Intersecting the two layers:

| `crown_land` basis | Parcels touched by a disposition | Share of that basis' area |
|--------------------|--------------------------------|---------------------------|
| `tenure_only` (no policy) | 2,741 of 11,780 | 0.3% |
| `clupa` (policy covers it) | 12,532 of 29,038 | 1.3% |

So the exposure is common but small: 15,273 Crown parcels have somebody's
disposition on them, yet only about 1% of Crown land area. These are camp- and
cottage-sized, which is exactly why the layer is `alwaysQueryable` and drawn with
a strong outline over a light fill — easy to pan past, and expensive to miss.

**Easements are excluded** (`CLASS_SUBTYPE <> 'Crown Disposition Easement'`). A
right of passage over Crown land does not create the exclusive occupation this
layer warns about, and including them would add bulk that says nothing about
whether you may be asked to leave.

**Each parcel is simplified against its own stated accuracy.** The province
publishes `LOCATION_ACCURACY` per feature, and it ranges from 1 m to 1000 m:

| Stated accuracy | Features | Share |
|-----------------|----------|-------|
| 100 m | 12,756 | 38.5% |
| 50 m | 8,590 | 25.9% |
| 20 m | 7,429 | 22.4% |
| 1 m | 3,082 | 9.3% |
| 10 m or better (excl. 1 m) | 1,268 | 3.8% |
| worse than 100 m | 42 | 0.1% |

87% carry far more vertices than 20 m accuracy supports, but 3,604 are mapped to
5 m or better, and flattening those to one tolerance would claim less precision
than the survey has while still labelling them `mapped`. So the tolerance is a
fifth of each feature's own stated error, floored at the 5 m the server already
applied and capped at 15 m. The 42 features worse than 100 m carry
`boundary_accuracy: approximate`. This took the layer from 27.2 MB to 19.6 MB
with no feature dropped; a flat 15 m would have reached about 17 MB and been less
honest.

`hunting_allowed`, `basis` and `boundary_accuracy` are stated once in the layer
header as `default_*` keys rather than repeated on all 33,167 features, which
alone accounts for 3 MB. The app fills them in at identify time via
`LoadedLayer.featureDefaults`, and only ever where a feature omitted the
property — an explicit null stays null, because in `crown_land` a null
`hunting_allowed` is an answer.

### Parcels with no policy default to Ontario's general rule

CLUPA covers the planning area, not the province. 3,342 of the 43,058 parcels
carry no `policy_id`, and by area that is still the larger half — 44.2 M ha
against 40.4 M ha — because most of the Far North sits outside the planning area
entirely. These are not slivers: the largest is 970,000 ha.

Where the planning area stops is measurable in the atlas's own
`AOU_DESIGNATION` column, which records whether an area is inside the Area of the
Undertaking, north of it, or south of it:

| AOU_DESIGNATION | Polygons | Area |
|-----------------|----------|------|
| Inside the AOU | 463 | 41.97 M ha |
| North of the AOU | 9 | 1.38 M ha |
| South of the AOU | 32 | 2,223 ha |
| Not stated (parks, reserves, wilderness and forest reserves, which come from other classes) | 757 | 11.00 M ha |

Two very different silences follow, and they must not be worded the same way.
**South of the AOU** the atlas holds 32 polygons totalling 2,223 ha — effectively
nothing — but there is almost no Crown land down there either, and what public
land exists is carried by the municipal forest, conservation authority and
conservation reserve layers instead. **North of it** the silence is the one that
matters: 2,571 of the 3,342 policy-free parcels sit above 51°N, and they hold
most of that 44.2 M ha. That is the case the `land_use_plan` layer and the
`tenure_only` basis note already exist to answer, and both still read correctly.

That is an absence of an *area-specific* policy, not an absence of a rule.
Ontario's own [recreational activities on Crown
land](https://www.ontario.ca/page/recreational-activities-on-crown-land) page
lists hunting among the things "you can usually use Crown land to" do, with a
valid licence, excluding provincial parks and conservation reserves. So the
`tenure_only` basis note states the general rule and then names what the map
cannot see: posted signage, an active land use permit or lease, or a local access
restriction.

`hunting_allowed` deliberately stays null rather than flipping to `true`. The
province says "usually" and "some restrictions may apply", and special hunting
areas under O. Reg. 665/98 are not modelled.

The badge for these parcels reads **"General rules apply, no local policy"**, in
the same amber as the conditional parcels. It used to read "Hunting generally
permitted" in a second, lighter green, and that was wrong in a way worth
recording: two shades of green cannot carry the difference between a source that
permits hunting here and a rule about Crown land in general, and the confident
one was being read as the permission nobody verified. Keeping the wording — this
is not "not on record", which reads as ignorance and sends people looking for an
answer that already exists — while dropping the green is what the amber does.

On the map the same distinction is drawn as less ink: policy-free parcels take
`fill-opacity` 0.15 against 0.30 for parcels a policy covers, from a data-driven
`case` expression on `basis`. Opacity rather than dashes, because MapLibre
documents data-driven `line-dasharray` on the web only, so per-feature dashes
cannot be done within a single layer on Android or iOS.

### Land use policy: bundled copy plus live link

Each Crown parcel carries a `policy_id`, and Land Info opens the policy two ways:

- **Bundled markdown** (`policies/<id>.md`, 1,219 files, ~6 MB) — works with no signal, which is the point of the app. Includes the official permitted-use table with the Hunting row verbatim.
- **Official report** — a link to the live document, which is the authority if the two ever disagree.

The report URL comes from `policy_report_url` in the province manifest, so it is data, not a hardcoded provincial endpoint. For Ontario:

```
https://www.lioapplications.lrc.gov.on.ca/services/CLUPA/xmlReader.aspx?xsl=web-primary.xsl&type=primary&POLICY_IDENT={id}
```

Note this is **not** the `URL_ENG` column shipped in CLUPAPRO. Those `crownlanduseatlas.mnr.gov.on.ca` links still return HTTP 200 but redirect to a generic landing page, silently dropping the policy — the endpoint above is the one Ontario's own CLUPA map service hyperlinks to.

### Not mapped: municipal discharge bylaws

Whether you may discharge a firearm at a given spot is set by municipal bylaw, and Ontario has no province-wide open dataset for it — Ottawa is the only municipality publishing its schedules spatially. Rather than ship a layer that silently covers one city out of 444, Land Info names the municipality so the user can look its bylaw up. The one place the bylaw is still used is as *evidence*: the four Ottawa forestry tracts it names as exempt are the only tracts flagged huntable in `municipal_forest`.

### Agreement Forest Area caveats

The dataset is the only open, parcel-level source for county/regional/municipal forest in Ontario, and it is what lets us draw the real patchwork instead of one polygon over the private land in between. Its limits are disclosed in the layer metadata and shown in Land Info:

- Ontario has **deprecated** it; records were verified in **1997–1998**, so some tracts have changed hands.
- Positional accuracy is mostly *"Reliable (to 100 m)"* — good enough to separate a public tract from the lot beside it, not a survey line.
- It carries **no ownership attribute**, so ownership is inferred from the tract name and only clearly public owners are kept. 516 parcels (~15.6k ha) with no establishable public owner are dropped, including corporate holdings (Domtar, CSLA) and federal NCC land. The layer under-reports rather than painting private woodlots green.
- Renfrew's 51 historical records use generic names such as *Indian River Tract*, so the name filter used to drop all of them. Their `LOCATION_DESCR` begins `Renfrew`, except Centennial Lake and Carswells Mountain where the source misspells it `Refrew`. The County's current page independently says it owns and manages 53 separate tracts as the Renfrew County Forest, and its official 2017 overview map names the 51 historical tracts. Those records are now classified as County forest. The count difference is left as a current-inventory gap rather than assuming which properties were acquired, disposed of, split or combined since 1998. The geometry is still Ontario's OGL-licensed Agreement Forest geometry. No data is copied from the County GIS, whose terms prohibit redistribution.
- The area corroborates the classification independently of the names: the County says the forest is "53 separate forested areas" covering "over 6,500 hectares", and the 51 records total 6,466 ha. A location filter that had swept in private woodlots would not land inside half a percent of the owner's own figure.
- Public ownership is **not** permission to hunt. The four City of Ottawa forestry tracts named in the firearms by-law (Marlborough, Carp Hills, Pinery-Long Swamp, Corkery) are flagged huntable. Renfrew's official page says hunting is permitted throughout the Renfrew County Forest except in active harvest operations, so its 51 mapped records are marked `conditional`, not given an unqualified green verdict; only portable or temporary stands are allowed, bear baiting needs a County land use agreement, and By-law 79-24 prohibits further activities. Every other tract is left "confirm with the municipality", since many county forests and most conservation authority land are permit-only or closed.
- This layer is where the quantize-then-validate rule was first needed; it is shared logic now, described under [Rounding a parcel must not be allowed to delete it](#rounding-a-parcel-must-not-be-allowed-to-delete-it).

### Crown parcel count: 43,058 of the province's 62,719

The provincial layer holds 62,719 unpatented parcels and we carry 43,058, which
is a discrepancy worth explaining rather than leaving to be discovered. The build
drops parcels under half a hectare. To check that this was not quietly deleting
usable ground, 300 of the excluded parcels were re-requested from the source at
full resolution: **96% are genuinely under half a hectare**, the largest was
0.8 ha, and nothing above 5 ha appeared at all. They are road and shore
allowances and survey remnants — smaller than the outline the map would draw for
them.

A further 413 never reach the build at all. The service generalises geometry to
about 20 m on the way out, and these collapse to a line at that tolerance. All
413 were re-requested at full resolution: the largest is **0.050 ha** and the
median is effectively zero, so every one of them would have failed the
half-hectare test anyway. `fetch_unpatented_on.py` counts them rather than
writing the collapsed remains out as degenerate features, which is what it used
to do.

Paging is ordered by `OGF_ID` and deduplicated by it, and the fetch fails if the
distinct count comes in under the layer's own `returnCountOnly`. ArcGIS only
guarantees a stable window across `resultOffset` requests when the query is
ordered, and a tenure layer that silently stops early does not look broken — it
looks like there is no Crown land there.

### Rounding a parcel must not be allowed to delete it

Quantizing coordinates to five decimals is what keeps this layer to a shippable
size, but a multipart parcel usually has at least one hair-thin part — a shore
allowance, a road strip — that rounding collapses to zero width. `make_valid`
then hands back a `GeometryCollection` of the surviving polygons *plus* those
dead rings as `LineString`s, and the build's type check threw the whole feature
away and counted it as a sliver.

That silently deleted **190 parcels covering 2.46M ha**, including a 970,410 ha
block, and it is how a user standing on a 190 ha Crown parcel in Fraser Township,
Renfrew County was shown no land tenure at all while iHunter showed Crown land.
`geomutil.polygonal()` now unpacks the collection instead of rejecting it: the
polygons are the ground the province mapped, and the linework is an artefact of
our own arithmetic. The build's `dropped_slivers` counter no longer absorbs the
difference — anything genuinely unusable is counted separately as
`dropped_invalid`, which is currently zero.

Rounding also breaks rings outright, by pinching a narrow neck into a
self-intersection, and a renderer fills an invalid ring with a hole or an
inversion. That is why `geomutil.quantized_valid()` checks validity **after**
rounding rather than before it, which is the order the layers originally used —
3,478 invalid polygons across seven Ontario layers came from getting it the wrong
way round. A repair is accepted only when it holds the feature's area to within
0.1%. Area is the right test and outline distance is not: rounding leaves
zero-width digitising spikes, `buffer(0)` rightly deletes them, and deleting one
moves the outline by the spike's whole length while changing the area by nothing.
Where the target grid cannot hold a parcel at all, a finer one is tried before
rounding is abandoned — the parcels that fail have a neck narrower than the grid,
so a finer grid answers them directly, and the alternative is shipping float64 in
full for sub-micron precision on a boundary the province surveyed to metres.

### CLUPA's `OVERLAY_IND` means the opposite of what it reads like

The build used to skip every CLUPA polygon with `OVERLAY_IND = Yes`, on the
assumption that those were supplementary overlay policies and the primary areas
were the ones to keep. LIO's own [data
description](https://www.publicdocs.mnr.gov.on.ca/mirb/CLUPA%20Provincial%20-%20Data%20Description.pdf)
defines the column the other way round: it "indicates whether a land use area
**is subject to** an overlay". Overlay policies live in a separate class
(`LIO_Open06/4`); every one of the 1,261 rows in `CLUPA_PROVINCIAL` joins to
`POLICY_TYPE_FLG = 'Primary'` in the province's own `CLUPA_POLICY.csv`.

So the filter was discarding 53 primary land use areas covering **6.94M ha**, and
it discarded them non-randomly: the areas most likely to have something overlaid
on them are the big district-wide General Use Areas, which is where people hunt.
The largest losses were General Mixed Use Areas (G1770, 1.72M ha), Resource
Utilization Area (G1729, 1.31M ha), Multiple Natural Resource Use (G396,
596k ha — the whole Pembroke District, and therefore all of Renfrew County) and
the Madawaska Highlands General Resource Area (G408, 78k ha).

Nothing filters on the column now. Restoring those 53 areas took the parcels
carrying a `policy_id` from 30,957 to 39,759 and dropped the ones left on the
`tenure_only` fallback from 11,756 to 3,342, and the bundled
policy markdown they point at was already shipping — `data/on/policies/G396.md`
has existed all along with its Hunting row and its Conroy Marsh game preserve
carve-out, unreachable because no feature referenced it.

Primary areas are all but disjoint, so this creates almost no ambiguity: exactly
one of the 1,208 unoverlaid polygons has its own centre inside another. Where two
do stack the build takes the smaller, since that is the area-specific direction
and the larger is the district-wide default it sits inside.

### Known gaps, in rough order of how much they matter

Recorded here so they are visible rather than implied. None of these is mapped
yet, and the app says nothing about them:

| Gap | Source that would close it | Why it matters |
|-----|---------------------------|----------------|
| Provincial Wildlife Areas and CLUPA overlays | CLUPA Provincial (17) and CLUPA Overlay (36) | Designations we already read the source for but do not carry |
| Far North parcels with neither atlas nor plan | Nothing publishes it | Most of the Far North has no area-specific direction at all. The card says so rather than implying the answer is elsewhere |
| Pinning the tapped point in the atlas | No marker parameter exists in GVH 4.14 | The atlas centres on the point but cannot mark it, so the dialog keeps the coordinates visible |
| Base-administered controlled hunts | No machine-readable source | Some bases open ground to civilians who apply and register daily. We draw the property as closed and link to its federal record, because the programmes are not published as data and change yearly |

Two datasets are deliberately **not** worth building. The Niagara Escarpment plan
layers regulate development, not hunting. And the eleven Special Hunting Areas in
Part 5 of O. Reg. 663/98 incorporate their boundaries by reference to schedules
as they read in 1990 or 1998, so no geometry is published and none can be
derived.

## Quebec

| Layer | Source | Notes |
|-------|--------|-------|
| Hunting zones | — | **Not shipped.** No licence permits redistribution; see below. `fetch_qc_real.py --zones` still builds it if that changes |
| Parks & protected | TRQ_WMS | National/provincial parks, reserves, refuges |
| Public hunt territories | TRQ ZECs / exclusive / outfitters | Green overlay proxy until full Crown tenure fabric ships |
| Municipalities (CSD) | StatsCan 2021 cartographic CSD | `fetch_municipalities_qc.py` (EPSG:3347 → WGS84) |
| Municipal forests | — | Empty schema; no province-wide open layer yet |

**License:** not one licence, and one of them is unresolved:

- **TRQ layers** (parks, protected areas, public hunt territories) are
  Attribution (CC-BY 4.0). Confirmed rather than inferred: the Données Québec
  package
  [couche-des-territoires-recreatifs-du-quebec](https://www.donneesquebec.ca/recherche/fr/dataset/7c9fff9f-c7c0-4267-a287-f86299796aea)
  (MRNF) carries that licence and lists our exact REST endpoint,
  `servicescarto.mrnf.gouv.qc.ca/pes/rest/services/Territoire/TRQ_WMS/MapServer`,
  among its own distributions — so the licence attaches to the thing we call, not
  to a dataset that resembles it.
- **Municipalities** are StatsCan [Open Licence](https://www.statcan.gc.ca/en/reference/licence).
- **Hunting zones (GAGQ) have no licence, and the search for one is finished.**
  The service states only `© Gouvernement du Québec`; it is the Greffe de
  l'arpenteur général locator service, published to help find survey documents
  rather than to distribute data. What was established:
  - Données Québec has no dataset for this geometry. Both ministries' complete
    catalogues were searched (248 datasets), plus full-text queries and a
    `resource_search` on the hostname, which returns zero.
  - The CC-BY *territoires récréatifs* product does not contain it. All 17 of its
    layers were enumerated; the closest are `Territoire exclusif de chasse` and
    `Zone d'exploitation contrôlée`, neither of which is a numbered regulatory
    zone.
  - **The analogy argues the other way.** The same ministry licenses its
    Territoires fauniques structurés under **CC-BY-NC-ND 4.0**, so for Quebec
    wildlife geometry the permissive guess is the wrong one.

  Redistributing it is therefore unlicensed until somebody grants it in writing,
  **so it is not shipped.** `build_wmu` is kept whole and reachable via
  `fetch_qc_real.py --zones`, because the answer may yet be yes; note that
  `build_pack.py` packs every GeoJSON in the overlays directory rather than only
  the ones the manifest names, so dropping the manifest entry alone would not have
  been enough — the fetch is what had to stop.

  Now was the cheapest possible moment to drop it. Quebec ships no seasons and no
  policy documents, so nothing was keyed to a zone and the layer only printed a
  number. The cost is a line missing from the card rather than an answer going
  wrong, and `LandInfo.wmuId` is nullable, so the card simply omits it.

  A request is outstanding with the Direction générale de la gestion de la faune
  (dggf@environnement.gouv.qc.ca). **To restore:** `fetch_qc_real.py --zones`, add
  the layer back to `data/qc/manifest.json`, and mention hunting zones again in
  the Quebec `statusNote` in `data/provinces.json`.

Quebec is flagged `"status": "preview"` in `data/provinces.json`, which puts a
PREVIEW badge in the app bar and a plain-language note behind it. The green
overlay is managed territory, not walk-on public land, and there are no seasons
or policy documents yet. Drop the flag when those land.

## Place names

| Layer | Source | Notes |
|-------|--------|-------|
| Gazetteer | [Canadian Geographical Names Database](https://natural-resources.canada.ca/maps-tools-and-publications/geographic-names) (NRCan) | 57,769 Ontario and 122,802 Quebec names via `fetch_cgndb.py`, written to `data/{cc}/gazetteer/places.json`. Curated by feature type, see below |

**License:** [OGL–Canada](https://open.canada.ca/en/open-government-licence-canada).
The credit line in the search sheet is a condition of it, so it stays.

This is what makes the search field accept "Mud Lake" as well as a coordinate.
It answers one question — where is the place with this name — and it is the only
dataset here that carries no legal weight at all: a gazetteer point is a label,
not a boundary, and tapping a result moves the map and nothing else. The Land
Info card still decides what the rules are at wherever you land.

### It is not a road network, and the UI must never suggest it is

CGNDB does contain named roads and trails. It contains them the way a lost and
found contains umbrellas: whatever happened to be filed. Across both provinces
the `ROAD` concise code holds 2,022 bridges, 577 trails, 518 portages and 373
hills that were misfiled, and almost no actual road names. There is no coverage
guarantee of any kind.

So the whole `ROAD` code is dropped, including the trails and portages that a
hunter would genuinely want. Carrying 577 trails out of the province's many
thousands would advertise a search the pack cannot do, and someone who found
one trail by name would reasonably conclude the rest were missing from the
world rather than from our file. The empty state in the sheet names what the
index does hold and says plainly that roads and trails are not in it.

Road names would need Statistics Canada's Road Network File, which is a
different dataset, a different size class and a different build. Nothing in the
app should imply it is there until it is.

### What is kept, and what is dropped

The filter is on CGNDB's `Concise Code`, 35 of the 292 codes present:

| Kept | Codes |
|------|-------|
| Water | `LAKE` `RIV` `BAY` `CHAN` `FALL` `RAP` `RIVF` `SPRG` `SEAU` |
| Land form | `ISL` `CAPE` `SHL` `MTN` `BCH` `VALL` `CLF` `PLN` `CRAT` `CAVE` `UNP` |
| Populated | `TOWN` `CITY` `VILG` `HAM` |
| Administrative | `GEOG` `MUN1` `MUN2` `IR` `PROV` `PARK` |
| Vegetation and use | `VEGL` `FOR` `MAR` `MIL` `CAMP` |

`MAR` is kept for boat launches, docks, locks and lighthouses; `MIL` for the
ranges and bases the app already warns about; `RIVF` for the named pools and
fishing holes on a river. Dropped, with the reason:

| Dropped | Why |
|---------|-----|
| `ROAD` | Bridges, trails and portages with no coverage guarantee. See above |
| `HYDR` | Dams, drains and pumping stations — infrastructure, not a destination |
| `SITE` | Monuments, plaques and parking lots |
| `RECR` | Libraries, arenas and community centres |
| `RES` | Quarries and mine sites |
| `AIR` | Airports |

Those six are urban and municipal furniture that would swell the index and the
result list without helping anyone find a lake. Ontario loses 541 records to
the filter and Quebec 8,429, which is the difference between 131,231 raw Quebec
rows and the 122,802 indexed.

### Duplicate names are the design problem

Ontario has 75 lakes called Mud Lake. Quebec has 168 called Lac Long. The point
of the index is therefore not finding a name — it is ordering the places that
share one, which is why each record carries its county or equivalent and the
sheet ranks by distance from the current map centre. 386 of Quebec's 1,397
county values and 186 of 292 feature types survive the filter and appear.

### Format

One JSON file per province, column-major rather than a list of objects, with
feature types and county names interned into lookup tables and referenced by
index. Ontario is **2.17 MB** and Quebec **5.10 MB** on disk; the same data as
one object per record is roughly three times that. Coordinates are stored as
integers scaled by 100,000 — about 1 m — so the file format itself cannot carry
a sixth decimal place it has no right to.

The index is read only when the user opens search, never at startup, and parsed
off the main isolate. `app/lib/data/gazetteer.dart` documents the search itself,
including why the folded names are held as bytes.

## Weather and conditions

| Source | Used for | License |
|--------|----------|---------|
| [Open-Meteo](https://open-meteo.com/) `/v1/forecast` | Current conditions, 168 hourly steps, 7 daily steps, sunrise/sunset | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

No API key and no sign-up, which is why it fits an app with no backend. Free-tier
limits are 10,000 calls a day, 5,000 an hour and 600 a minute; responses are
cached for 15 minutes per ~1 km coordinate bucket so panning does not spend that
budget. **The free tier is non-commercial only** — monetizing the app means
buying a plan or self-hosting. Attribution is a licence condition, so the credit
line at the bottom of the Weather tab has to stay.

This is the only feature that needs a network. It is additive: with no
connection the tab explains itself and the rest of the card still works.

### Deer activity is a heuristic, not data

The activity graph is editorial. It is documented in
`app/lib/weather/activity.dart` with each factor graded by how well it is
actually supported: crepuscular timing and rut timing are well established,
temperature against local normal is well supported, wind and heavy precipitation
are moderate, and pressure change is weak and therefore weighted lightly. Moon
phase is deliberately excluded because the telemetry studies that look for an
effect on daily movement mostly fail to find one, and including it would add
false authority.

Every hour exposes the factors that produced its score, hours outside legal light
are faded rather than hidden, and the whole graph can be switched off.

## Alberta (optional stub)

Same layer slots as ON/QC when added; use Alberta Open Government datasets.

## Basemap imagery

The satellite basemap stacks government orthophotography over a global fallback,
so zooming in over ON/QC shows real aerial detail instead of 10 m satellite pixels.

| Layer | Source | Zoom | License |
|-------|--------|------|---------|
| Ontario orthophotography | [Ontario Imagery Web Map Service](https://data.ontario.ca/dataset/open-ontario-imagery) (LIO) | to z19 | Open Government Licence – Ontario |
| Quebec orthophotography | MRNF `Imagerie_Continue` WMTS | to z20 | Licence ouverte du Québec |
| Global fallback | Sentinel-2 cloudless © EOX | to z14 | CC BY-NC-SA / Copernicus |

Ontario returns 404 outside its coverage so the fallback shows through cleanly.
Quebec returns a flat placeholder tile in coverage gaps, so its source is bounded
to Quebec and drawn beneath Ontario's.

### Vector map data

| Layer | Source | Zoom | License |
|-------|--------|------|---------|
| Streets basemap, and the labels in Hybrid | [OpenFreeMap](https://openfreemap.org/) Liberty, OpenMapTiles schema | to z14 | Data © OpenStreetMap contributors (ODbL); schema © OpenMapTiles (BSD-3) |

The Hybrid basemap is generated from Liberty by
`tools/gis/build_hybrid_style.py`, which keeps the road, watercourse, boundary
and label layers, drops the fills and points of interest that imagery already
shows, and recolours the text to white on a dark halo so it survives over aerial
photography. Regenerate it when OpenFreeMap updates the style; the script fails
rather than silently dropping a layer that has been renamed.

OpenFreeMap versions its tile URLs by planet build date. An area saved offline
keeps working because the TileJSON that names those URLs is saved with it, but a
saved Streets or Hybrid area will not pick up a newer planet without being saved
again.

### Tile weights

`tools/gis/measure_tile_sizes.py` samples each endpoint across city, farmland
and bush in both provinces, and its medians are what
`app/lib/offline/basemap_sources.dart` uses to estimate a download before it
starts. Re-run it if a source changes; the estimate is only as honest as those
numbers.

## Waypoint glyphs: Material Icons, Apache 2.0

The only artwork the app bundles. `tools/icons/build_waypoint_icons.py` renders one
glyph per `WaypointIcon` out of the Material Icons font that ships with the
Flutter SDK, and converts each to a signed distance field so MapLibre can tint it
per waypoint with `icon-color` instead of us shipping one PNG per colour. Source
and licence are recorded in `app/assets/waypoint_icons/manifest.json`, which ships
with the images.

One image is not the glyph as the font has it. The optional pin marker style needs a
solid backdrop for a light glyph to read against, and Material Icons has no solid
pin: `place` is a teardrop with a circular counter punched out of exactly the part
the glyph has to sit on. The generator closes that counter — a deterministic hole
fill of the same Material outline, not new artwork — and records where the pin's
point and the centre of its head land in the image, because the app needs both to
keep a waypoint drawn on the coordinate it was saved at. A Dart test reads those
measurements back out of the manifest, so regenerating the pin cannot quietly move
every waypoint on the map.

Chosen over the CC0 outdoor sets (Temaki, Maki, Osmic) because it is already in the
dependency tree, so it adds no download and no licence to audit. Swapping one glyph
for another Material glyph is a codepoint here and a codepoint in the generator.
Swapping one for an SVG from another set is not: the generator rasterises by
codepoint through PIL, which cannot read SVG, and `WaypointIcon.icon` is an
`IconData` that the list rows, the editor chips and the map all read from, so a
single non-font icon would need an SVG rasteriser in the build, `flutter_svg` in the
app, a branch at every draw site, and an exemption from the test that stops the list
glyph and the map glyph diverging. Worth it for a whole set, not for one icon.

Some of the set are compromises worth knowing about. Material has no ground blind,
so `blind` borrows a shelter — a house with a bed, which reads more like a hostel
than a hide — and `stand` uses a plain chair, which is not a tree stand either but
is at least unambiguously a seat. `firepit` is labelled "Fire or grill" because the
glyph is plainly a kettle grill, and `foraging` is a leaf standing in for both
mushrooms and berries, neither of which Material has. A gate, a bridge, a bench and
a water spring have no honest glyph at all, so they are absent rather than
represented by something that means another thing.

The glyph is a picture and carries no classification: what a waypoint *is* lives in
its tags. It does carry a default colour, and for the twenty glyphs that used to be
categories those are the exact colours those categories had, so a waypoint saved
before the split draws in the colour it always drew in. Changing one repaints
waypoints already on someone's phone, which is why a test pins them.

Where the glyph goes when a waypoint leaves the app is a separate question from what
it looks like here — see the export notes in `app/lib/waypoints/import_export.dart`.
GPX `<sym>` values are the display names from GPSBabel's `garmin_icon_tables.h`,
which is the reference the GPX ecosystem shares, and are omitted rather than
guessed where Garmin has no matching symbol; every glyph added since the icon
stopped being a category omits it, because guessing at a plausible Garmin name
would be inventing a fact about someone else's device. Tags travel in GPX `<type>`
comma separated and in `<cmt>` as `#hashtags`, since different tools drop different
fields, and import takes the union. KML folders mean the glyph rather than tags: a
KML folder has one parent, so a two-tag waypoint would be written twice, and since
KML carries no id, re-importing would duplicate it.

## Pack layout

Nothing province-specific is bundled in the app binary — only `data/provinces.json`
(the catalogue and pack URLs). Everything below ships in the downloadable pack.

```
data/{cc}/
  manifest.json      # layer list + overlay paths
  overlays/          # .geojson / .pmtiles per layer
  seasons/           # YYYY.json (Ontario)
  policies/          # generated markdown, one per policy id
  gazetteer/         # places.json, the place-name search index
```

## Attributes (Land Info minimum)

- **crown_land:** use class / designation, management unit if available
- **wmu:** unit id, season notes field if present in source
- **parks:** name, designation (park, reserve, …), restrictions flag
- **townships / municipalities:** official name, type
- **municipal_forest:** name, managing body

Do not commit full province tiles to git—Releases only (see `docs/contributing.md`).

Geometry packs refresh monthly via Actions (`packs-latest`). Seasons are re-scraped
by the **Refresh hunting seasons** workflow, which opens a PR rather than pushing:
hunters act on these dates, so a human checks the diff against the official tables
first. See the `refresh-seasons-policies` skill.
