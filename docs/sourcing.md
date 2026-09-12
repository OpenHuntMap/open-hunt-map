# Finding a source, and knowing when to trust it

[`datasets.md`](datasets.md) records what each layer is and where it came from.
This records how to find the next one and how to tell whether it is right, which
is a different skill and was learned the hard way: a commercial app was correct
and we were wrong at two coordinates a user checked by hand, and neither error
was visible on our own map.

## The division that decides everything else

**A GIS layer draws the boundary. A regulation decides the answer.** Almost no
Ontario GIS layer carries permission, so nearly every legal-answer layer here is
a join of two unrelated sources:

| Layer | Boundary from | Answer from |
| --- | --- | --- |
| Provincial parks | LIO Provincial Park Regulated | O. Reg. 663/98 Part 3, plus PPCRA s. 15 (2) for Algonquin |
| Conservation reserves | LIO Conservation Reserve Regulated | PPCRA ss. 15 (3), 12 (3) |
| Crown land | MNR unpatented parcels | CLUPA policy report per parcel |
| Sunday gun hunting | WMU boundary fabric | O. Reg. 665/98 s. 66 (1) and O. Reg. 663/98 Part 7 Schedule 1 |
| Federal wildlife areas | CPCAD | C.R.C. c. 1609 and c. 1036 |

If you find yourself with a boundary and no provision, you have half a layer.
Shipping it looks like an answer and is not one.

## Where Ontario's authoritative geometry actually lives

LIO's ArcGIS REST services are the primary source, in the shape
`https://ws.lioservices.lrc.gov.on.ca/arcgis2/rest/services/LIO_OPEN_DATA/LIO_OpenNN/MapServer/N/query`.
Two things about them are worth knowing before you spend an afternoon:

- Paginate with `resultOffset`; the services cap a response well below most
  layers' feature counts and do not warn you that you got a partial answer.
- Requesting full-resolution geometry on a large layer makes the service reply
  with an HTML error page rather than JSON. Pass a simplification tolerance
  (`maxAllowableOffset`), which is why the fetch scripts all carry a `--simplify`.

The dataset pages on `data.ontario.ca` and `geohub.lio.gov.on.ca` carry the
licence and the field definitions; the REST endpoint carries the data. You need
both, because the field you want is often not named what it means — CLUPA's
`OVERLAY_IND` is the standing example and it means the opposite of how it reads.

Federal sources used here: CPCAD (ECCC) for protected areas, the Canada Lands
Survey System (NRCan) for reserves, DFRP (Treasury Board) for defence property.
Where a province does not publish a usable municipal fabric, StatCan's census
subdivision boundary files do (this is what Quebec uses).

## Reading the law without a paywall

- **e-Laws has a v2 API** that serves the consolidated current version as
  structured data, and `parse_reg663_on.py` uses it. This matters more than it
  sounds: the human-readable `ontario.ca/laws/regulation/...` page is
  JavaScript-gated and cannot be fetched at all, so it is easy to conclude the
  regulation is unreachable and start transcribing by hand. It is not.
- Justice Laws (`laws-lois.justice.gc.ca`) serves federal regulations as plain
  HTML and fetches fine.
- CanLII returns 403 to scripts. Do not build anything on it.
- Informational `ontario.ca/page/...` articles fetch fine but need a browser
  `User-Agent`; the default Python one gets refused.

## How we found out we were wrong

The method that worked, in order. Step 4 is the one people skip.

1. **Start from a disagreement at a real coordinate.** A user checked two points
   against iHunter. One showed Crown land where we showed nothing; the other
   showed a named county forest tract we did not have at all.
2. **Ask what layer the other app must be reading**, from its own vocabulary.
   "Multiple General Resources" in purple is CLUPA *policy* language, not a
   tenure class — which said immediately that we had the parcels and were missing
   the policy join, rather than missing the parcels.
3. **Find the open source that publishes that layer**, and confirm which field
   carries the classification. This is where the field-naming traps live.
4. **Verify the rebuilt layer against a total the publisher states
   independently.** Renfrew County publishes the area of its forest holdings, so
   the 51 tracts we recovered had to add up to roughly that figure, and they did.
   A layer that looks plausible on a map and matches nobody's published number is
   not verified — it is just drawn.

For a derived layer with no published total, verify against geography you can
name. The French/Mattawa divide was checked by asserting which side of it eleven
known towns fall on, and against the ministry's own list of WMUs at the divide.

## Verifying before it reaches a phone

```powershell
python tools\gis\audit_overlays.py            # every enabled province
python tools\gis\audit_overlays.py --skip-divide   # faster, less thorough
```

`rebuild_geometry.py` runs this before it packs anything, so a scheduled rebuild
cannot publish overlays that fail it. Four checks, each of which exists because
the thing it looks for actually shipped:

- **Validity.** Invalid rings make Shapely's point-in-polygon answers unreliable,
  so an invalid parcel is not cosmetic — the Land Info card may simply answer
  wrongly.
- **The divide corridor.** No point near the French and Mattawa rivers may be
  left uncovered, because the card reads an absent feature as a prohibition.
- **Attribution.** Every layer carrying features names its source, licence and
  licence URL. A layer with no features must instead explain why it is empty.
- **Known answers.** Five coordinates whose answers were checked by hand, two of
  them on a phone. These would have caught both original bugs.

A green audit says the geometry is sound. It says nothing about whether the card
words the answer correctly, which still needs a device pass — see
[`devtest.md`](devtest.md).

## Things not to do, each learned by doing them

- **Do not use OpenStreetMap for anything implying tenure.** Context only.
- **Do not fill in a licence field by analogy with a sibling dataset**, and note
  that Quebec is the case that proves the analogy runs the wrong way. Its hunting
  zones service names no licence, and it would have been easy to write CC-BY 4.0
  because the neighbouring products use it — but the same ministry licenses its
  **Territoires fauniques structurés under CC-BY-NC-ND 4.0**. For Quebec wildlife
  geometry the optimistic guess is the incorrect one.
- **Do not swap a source for a more convenient one without re-reading its
  licence.** TFS is the standing trap: it covers ZECs, outfitters and réserves
  fauniques — the same subject matter as our Quebec public-territories layer —
  and it offers ready-made GeoJSON, GPKG and SQLite downloads where the layer we
  actually use requires paginating an ArcGIS service. Switching to it would look
  like a tidy simplification and would quietly put non-commercial, no-derivatives
  data in the app. We use the **territoires récréatifs (TRQ)** product instead,
  which is CC-BY 4.0 and whose Données Québec package lists our exact REST
  endpoint among its own distributions.

### Checking a licence properly, when the portal fights you

`donneesquebec.ca` is JavaScript-gated and cannot be read by a script, which is
what makes it tempting to give up and assume. It runs CKAN, and the CKAN JSON API
is open:

```
https://www.donneesquebec.ca/recherche/api/3/action/package_search?q=...
https://www.donneesquebec.ca/recherche/api/3/action/package_show?id=<slug>
https://www.donneesquebec.ca/recherche/api/3/action/resource_search?query=url:<host>
```

`resource_search` on the hostname is the decisive one: it answers "which licensed
dataset publishes the endpoint I am actually calling", rather than "which dataset
sounds like the thing I want". That is how the TRQ licence was tied to our own URL,
and how the hunting zones were shown to have no dataset behind them at all.
- **Do not cut a boundary before simplifying it.** Simplifying afterwards moves
  the cut edges independently and they stop meeting; that produced 1,015 slivers
  along the divide, each one a false "not permitted".
- **Do not round coordinates after validating them.** Rounding can push a ring
  onto itself. Round first, then validate, using the finer-grid ladder in
  `geomutil.quantized_valid` so a parcel is never deleted for being small.
