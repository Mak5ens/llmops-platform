<!-- AGENTS-TEMPLATE-START -->
# AGENTS.md — llmops-platform

> La connaissance ne vit pas ici : elle vit dans l'espace **mak5ens**, servi par le MCP
> `lore` (branché par le `.mcp.json` de ce repo). Ce fichier décrit le comportement attendu.

## En attendant QG

Le MCP `lore` n'est pas encore en service et ce repo n'a pas encore de `.mcp.json`. D'ici là,
le lore se lit dans son clone local, rangé à côté de ce repo : `../mak5ens-lore`
(`git clone git@github.com:Mak5ens/mak5ens-lore.git` s'il manque). Les tools cités plus bas se traduisent ainsi :

- `read_file("<chemin>")` : lire `../mak5ens-lore/<chemin>` ;
- `list_tasks(repo: "llmops-platform")` : lire `repos/llmops-platform/todo.md` ; `start_task` : déplacer la
  ligne dans « En cours » ;
- `search("<nom>")` : `grep -r` dans le clone ;
- `create_task`, `open_debt`, `create_adr`, `edit_file` : écrire le fichier à la main d'après
  le `_template.md` du dossier, puis commiter et pousser le lore (`docs: …`).

Cette section disparaît quand QG est déployé.

## Brancher le MCP

Ce repo versionne un `.mcp.json` qui pointe sur l'espace **mak5ens** et rien d'autre. Une
seule chose à faire par poste : exporter `LORE_TOKEN` (jeton `lore_` créé dans Paramètres →
Jetons). Ne pas ajouter d'autre serveur `lore` au niveau utilisateur.

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
