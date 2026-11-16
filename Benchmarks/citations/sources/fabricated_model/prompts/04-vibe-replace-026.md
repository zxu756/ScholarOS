You are one step in a relay of coding agents from different vendors. Other agents handle the other steps; do only this one, and don't start other agents or relay tools.

Goal: replace one entry in a file of 40 fabricated bibliography entries. The file is test data for a citation checker: every entry is an invented reference that must not correspond to a real publication or to a real researcher. A reviewer found that entry `fab_vibe_026` uses the author name "Chami, Fatuma A.", which in abbreviated form ("Chami, F. A.") is the same as a real archaeologist of the Swahili coast. That entry has to be rewritten with a different invented work and a different invented author.

Working directory: <working directory> (you are already in it)

Input: fabricated/vibe.bib (read it to see the entry and the style of its neighbours).

Deliverable: fabricated/vibe.bib with only the entry `fab_vibe_026` changed. Every other byte of the file must stay exactly as it is.

The new entry:
- Key `fab_vibe_026`, type `@book`, topic: ceramics trade on the medieval Swahili coast.
- A new invented title (not the current one, and not the title of any real book you know of).
- One invented author. Do not use the surname Chami, and do not use the name of any real researcher of East African or Swahili-coast archaeology, in full or in abbreviated form; if a name comes to mind because you associate it with this topic, that is the name not to use. Write it as `Surname, Given`.
- A real academic publisher, an address if the neighbouring book entries have one, a year between 1996 and 2024.
- No identifier of any kind: no doi, eprint, pmid, url, isbn, issn, howpublished or note field.

How to work: edit the file once with your file-editing tool, replacing just that entry. Do not regenerate or rewrite the file with a script. Then run `python3 tools/check_batch.py fabricated/vibe.bib vibe` once; it must print OK. Do not use any network tool.

Constraints: no git commit or push, no package installs, no network access, don't modify other files.

When you are done, reply in one short paragraph: the new entry's author, title, publisher and year, and what the checker printed. End with a line of its own: STATUS: success, STATUS: partial or STATUS: failed.
