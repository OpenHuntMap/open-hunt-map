#!/usr/bin/env python3
"""DEPRECATED — use fetch_qc_real.py + fetch_municipalities_qc.py instead.

Historically generated Outaouais/Gatineau stub rectangles for data/qc/.
Do not re-run; it would overwrite real province-wide overlays.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def ring(*coords: tuple[float, float]) -> list[list[float]]:
    closed = [list(c) for c in coords]
    if closed[0] != closed[-1]:
        closed.append(closed[0])
    return closed


def feature(props: dict, coords: list[list[float]]) -> dict:
    return {
        "type": "Feature",
        "properties": props,
        "geometry": {"type": "Polygon", "coordinates": [coords]},
    }


def metadata(layer: str, count: int) -> dict:
    return {
        "crs": "EPSG:4326",
        "province": "qc",
        "layer": layer,
        "feature_count": count,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": "tools/gis/generate_qc_sample.py",
        "license": "Licence-ouverte-Quebec",
        "license_url": "https://www.donneesquebec.ca/fr/licence/",
        "attribution": (
            "Données ouvertes du gouvernement du Québec; "
            "limites Statistics Canada sous licence ouverte Statistics Canada."
        ),
        "note": "Regional sample — simplified polygons for Outaouais/Gatineau demo.",
    }


def collection(layer: str, features: list[dict]) -> dict:
    return {
        "type": "FeatureCollection",
        "metadata": metadata(layer, len(features)),
        "features": features,
    }


def crown_land_features() -> list[dict]:
    return [
        feature(
            {
                "id": "qc-cl-001",
                "name": "Forêt domaniale — secteur Gatineau-Nord",
                "designation": "General Use Area",
                "policy_id": "UQ-01",
                "hunting_allowed": True,
                "summary": (
                    "Territoire domanial au nord de Gatineau. Chasse au petit gibier "
                    "et au cerf de Virginie permise selon les saisons du Québec; "
                    "respecter les limites du parc de la Gatineau adjacent."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-75.98, 45.52),
                (-75.82, 45.50),
                (-75.78, 45.56),
                (-75.80, 45.64),
                (-75.92, 45.68),
                (-76.02, 45.62),
                (-76.05, 45.54),
            ),
        ),
        feature(
            {
                "id": "qc-cl-002",
                "name": "Bloc couronne Outaouais-Est",
                "designation": "Enhanced Management Area",
                "policy_id": "UQ-02",
                "hunting_allowed": "conditional",
                "summary": (
                    "Zone de gestion intensifiée avec coupes planifiées. Chasse autorisée "
                    "hors secteurs d'exploitation active; consulter l'affichage sur place."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-75.72, 45.56),
                (-75.58, 45.54),
                (-75.52, 45.60),
                (-75.55, 45.68),
                (-75.68, 45.70),
                (-75.76, 45.64),
            ),
        ),
        feature(
            {
                "id": "qc-cl-003",
                "name": "Territoire couronne Petite-Nation",
                "designation": "General Use Area",
                "policy_id": "UQ-03",
                "hunting_allowed": True,
                "summary": (
                    "Parcelle domaniale mixte feuillue-conifère. Règlement général de chasse "
                    "du Québec applicable; vérifier la zone de chasse et les périodes légales."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-75.58, 45.42),
                (-75.42, 45.40),
                (-75.38, 45.48),
                (-75.44, 45.56),
                (-75.58, 45.58),
                (-75.64, 45.50),
            ),
        ),
        feature(
            {
                "id": "qc-cl-004",
                "name": "Forêt publique — Pontiac-Ouest",
                "designation": "General Use Area",
                "policy_id": "UQ-01",
                "hunting_allowed": True,
                "summary": (
                    "Massif forestier public à l'ouest de la rivière des Outaouais. "
                    "Zone de chasse 9; permis et dates légales requis."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-76.18, 45.48),
                (-76.02, 45.46),
                (-75.98, 45.54),
                (-76.04, 45.62),
                (-76.16, 45.60),
                (-76.22, 45.52),
            ),
        ),
        feature(
            {
                "id": "qc-cl-005",
                "name": "Bloc couronne La Pêche",
                "designation": "Enhanced Management Area",
                "policy_id": "UQ-02",
                "hunting_allowed": "conditional",
                "summary": (
                    "Secteur de gestion forestière autour de Wakefield. Chasse permise "
                    "sauf durant les opérations de récolte signalées."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-76.02, 45.68),
                (-75.88, 45.66),
                (-75.84, 45.74),
                (-75.90, 45.82),
                (-76.06, 45.84),
                (-76.12, 45.76),
            ),
        ),
        feature(
            {
                "id": "qc-cl-006",
                "name": "Territoire couronne Val-des-Monts",
                "designation": "General Use Area",
                "policy_id": "UQ-03",
                "hunting_allowed": True,
                "summary": (
                    "Étendue domaniale entre lacs et collines au nord-est de Gatineau. "
                    "Accès par chemins forestiers; vérifier les règlements municipaux adjacents."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-75.72, 45.62),
                (-75.58, 45.60),
                (-75.54, 45.68),
                (-75.60, 45.76),
                (-75.74, 45.78),
                (-75.80, 45.70),
            ),
        ),
        feature(
            {
                "id": "qc-cl-007",
                "name": "Forêt publique — Cantley sud",
                "designation": "General Use Area",
                "policy_id": "UQ-01",
                "hunting_allowed": True,
                "summary": (
                    "Parcelle domaniale entre Cantley et Chelsea. Chasse au cerf et "
                    "au petit gibier selon la zone 10."
                ),
                "source": "MFFP — Carte des activités forestières (échantillon)",
                "updated": "2024-10-20",
                "province": "QC",
            },
            ring(
                (-75.86, 45.48),
                (-75.78, 45.46),
                (-75.74, 45.52),
                (-75.78, 45.58),
                (-75.88, 45.56),
            ),
        ),
    ]


def municipality_features() -> list[dict]:
    return [
        feature(
            {"name": "Gatineau", "type": "municipality", "province": "QC"},
            ring(
                (-75.78, 45.38),
                (-75.62, 45.36),
                (-75.48, 45.40),
                (-75.42, 45.48),
                (-75.50, 45.56),
                (-75.68, 45.58),
                (-75.82, 45.52),
                (-75.86, 45.44),
            ),
        ),
        feature(
            {"name": "Chelsea", "type": "municipality", "province": "QC"},
            ring(
                (-75.96, 45.48),
                (-75.84, 45.46),
                (-75.78, 45.52),
                (-75.80, 45.60),
                (-75.90, 45.64),
                (-76.00, 45.58),
                (-76.02, 45.50),
            ),
        ),
        feature(
            {"name": "La Pêche", "type": "municipality", "province": "QC"},
            ring(
                (-76.12, 45.62),
                (-75.96, 45.60),
                (-75.90, 45.70),
                (-75.94, 45.82),
                (-76.08, 45.86),
                (-76.18, 45.78),
                (-76.16, 45.66),
            ),
        ),
        feature(
            {"name": "Pontiac", "type": "municipality", "province": "QC"},
            ring(
                (-76.28, 45.42),
                (-76.08, 45.40),
                (-76.02, 45.48),
                (-76.06, 45.58),
                (-76.20, 45.62),
                (-76.32, 45.54),
                (-76.30, 45.46),
            ),
        ),
        feature(
            {"name": "Cantley", "type": "municipality", "province": "QC"},
            ring(
                (-75.88, 45.44),
                (-75.78, 45.42),
                (-75.72, 45.48),
                (-75.74, 45.56),
                (-75.84, 45.58),
                (-75.92, 45.52),
            ),
        ),
        feature(
            {"name": "Val-des-Monts", "type": "municipality", "province": "QC"},
            ring(
                (-75.78, 45.58),
                (-75.62, 45.56),
                (-75.56, 45.64),
                (-75.60, 45.74),
                (-75.76, 45.78),
                (-75.86, 45.70),
                (-75.84, 45.62),
            ),
        ),
    ]


def wmu_features() -> list[dict]:
    return [
        feature(
            {
                "wmu_id": "9",
                "name": "Zone de chasse 9 — Pontiac",
                "province": "QC",
            },
            ring(
                (-76.35, 45.38),
                (-76.05, 45.36),
                (-75.98, 45.44),
                (-76.00, 45.58),
                (-76.18, 45.66),
                (-76.32, 45.60),
                (-76.38, 45.48),
            ),
        ),
        feature(
            {
                "wmu_id": "10",
                "name": "Zone de chasse 10 — Outaouais",
                "province": "QC",
            },
            ring(
                (-75.98, 45.36),
                (-75.72, 45.34),
                (-75.58, 45.40),
                (-75.54, 45.52),
                (-75.62, 45.64),
                (-75.82, 45.68),
                (-75.96, 45.60),
                (-76.00, 45.48),
            ),
        ),
        feature(
            {
                "wmu_id": "11",
                "name": "Zone de chasse 11 — Papineau",
                "province": "QC",
            },
            ring(
                (-75.58, 45.36),
                (-75.35, 45.34),
                (-75.30, 45.44),
                (-75.36, 45.58),
                (-75.52, 45.62),
                (-75.58, 45.50),
            ),
        ),
    ]


def park_features() -> list[dict]:
    return [
        feature(
            {
                "name": "Parc de la Gatineau",
                "park_type": "national_park",
                "hunting_allowed": False,
            },
            ring(
                (-75.92, 45.42),
                (-75.82, 45.44),
                (-75.74, 45.50),
                (-75.70, 45.58),
                (-75.72, 45.68),
                (-75.78, 45.78),
                (-75.88, 45.90),
                (-75.98, 45.98),
                (-76.06, 45.94),
                (-76.08, 45.82),
                (-76.02, 45.68),
                (-75.98, 45.54),
                (-75.96, 45.46),
            ),
        ),
        feature(
            {
                "name": "Parc régional du Bois-de-l'Île-Bizeau",
                "park_type": "regional_park",
                "hunting_allowed": False,
            },
            ring(
                (-75.76, 45.50),
                (-75.68, 45.49),
                (-75.64, 45.54),
                (-75.66, 45.58),
                (-75.74, 45.57),
            ),
        ),
        feature(
            {
                "name": "Réserve écologique de la Petite-Cascade",
                "park_type": "ecological_reserve",
                "hunting_allowed": False,
            },
            ring(
                (-75.66, 45.40),
                (-75.54, 45.39),
                (-75.50, 45.44),
                (-75.52, 45.50),
                (-75.64, 45.51),
            ),
        ),
        feature(
            {
                "name": "Parc régional de la Lièvre",
                "park_type": "regional_park",
                "hunting_allowed": False,
            },
            ring(
                (-75.58, 45.52),
                (-75.48, 45.51),
                (-75.44, 45.56),
                (-75.46, 45.62),
                (-75.56, 45.63),
            ),
        ),
        feature(
            {
                "name": "Réserve faunique de Papineau-Labelle (secteur sud)",
                "park_type": "wildlife_reserve",
                "hunting_allowed": False,
            },
            ring(
                (-75.48, 45.58),
                (-75.36, 45.56),
                (-75.32, 45.64),
                (-75.38, 45.72),
                (-75.50, 45.74),
                (-75.54, 45.66),
            ),
        ),
    ]


def municipal_forest_features() -> list[dict]:
    return [
        feature(
            {
                "name": "Boisé de Hull",
                "owner": "Ville de Gatineau",
                "hunting_notes": (
                    "Forêt urbaine municipale. Chasse interdite; décharge d'armes "
                    "à feu prohibée par règlement municipal."
                ),
            },
            ring(
                (-75.74, 45.44),
                (-75.70, 45.43),
                (-75.68, 45.46),
                (-75.70, 45.48),
                (-75.74, 45.47),
            ),
        ),
        feature(
            {
                "name": "Forêt municipale de Chelsea (secteur Pingo)",
                "owner": "Municipalité de Chelsea",
                "hunting_notes": (
                    "Sentiers récréatifs en usage intensif. Chasse non permise "
                    "à l'intérieur des limites."
                ),
            },
            ring(
                (-75.88, 45.52),
                (-75.84, 45.51),
                (-75.82, 45.54),
                (-75.84, 45.56),
                (-75.88, 45.55),
            ),
        ),
    ]


def write_layer(out_dir: Path, name: str, features: list[dict]) -> None:
    path = out_dir / f"{name}.geojson"
    data = collection(name, features)
    with path.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    print(f"wrote {path.name}: {len(features)} features")


def main() -> None:
    out_dir = repo_root() / "data" / "qc" / "overlays"
    out_dir.mkdir(parents=True, exist_ok=True)

    write_layer(out_dir, "crown_land", crown_land_features())
    write_layer(out_dir, "municipalities", municipality_features())
    write_layer(out_dir, "wmu", wmu_features())
    write_layer(out_dir, "parks", park_features())
    write_layer(out_dir, "municipal_forest", municipal_forest_features())


if __name__ == "__main__":
    main()
