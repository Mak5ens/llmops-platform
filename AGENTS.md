<!-- AGENTS-TEMPLATE-START -->
# AGENTS.md — llmops-platform

> La connaissance ne vit pas ici : elle vit dans l'espace **mak5ens**, servi par le MCP
> `lore` (branché par le `.mcp.json` de ce repo). Ce fichier décrit le comportement attendu.

## Brancher le MCP

Ce repo versionne un `.mcp.json` qui pointe sur l'espace **mak5ens** et rien d'autre. Une
seule chose à faire par poste : exporter `LORE_TOKEN` (jeton `lore_` créé sur
https://qg.labbtech.fr, page Jetons et MCP). Ne pas ajouter d'autre serveur `lore` au niveau utilisateur.

Cursor / Codex : même URL, même en-tête, dans leur fichier de configuration de projet.

## Avant toute tâche
1. `read_file("repos/llmops-platform/llmops-platform.md")` — rôle, dépendances, sensibilité.
2. `list_tasks(repo: "llmops-platform")` — en cours et à faire ; `start_task("<ID>")` sur celle qu'on
   traite, puis créer la branche renvoyée.
3. Avant de toucher un contrat (message, schéma, endpoint, librairie partagée) :
   `search("<nom>")` et lire les fiches qui le citent.

## Pendant et après
- Tâches : identifiant dans le titre de la MR (elle passe seule en revue puis en fait) ;
  tâches de suite avec `create_task`.
- Dette introduite sciemment : `open_debt`, marqueur `DEBT-xxxx` dans le code, lien dans la MR.
- Décision structurante : `create_adr`.
- Fiche du repo fausse : la corriger (`edit_file`) dans la même MR.

## Définition de fini
En production · recette validée · MR relue par un autre que l'auteur · fiche à jour · dette déclarée.
<!-- AGENTS-TEMPLATE-END -->

## Règles propres à ce repo

Commandes de build et de test : voir le `README.md`.
