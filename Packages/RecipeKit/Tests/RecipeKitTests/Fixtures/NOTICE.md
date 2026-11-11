# Test fixture sources and licenses

These files are test inputs for the RecipeKit importer. They are not part of the app.

## Wikibooks: Kung Pao Chicken (CC BY-SA 4.0)

`wikibooks-kung-pao-chicken.html` and `wikibooks-kung-pao-chicken-mobile.html` are copies of a Wikibooks page.

- Title: "Cookbook:Kung Pao Chicken"
- Source: https://en.wikibooks.org/wiki/Cookbook:Kung_Pao_Chicken (revision 4518961: https://en.wikibooks.org/w/index.php?title=Cookbook:Kung_Pao_Chicken&oldid=4518961)
- Authors: Wikibooks contributors; see the page history at https://en.wikibooks.org/w/index.php?title=Cookbook:Kung_Pao_Chicken&action=history
- License: Creative Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0), https://creativecommons.org/licenses/by-sa/4.0/
- Changes: `wikibooks-kung-pao-chicken.html` keeps only the title, the infobox and the article body; most page markup, scripts and navigation were removed. `wikibooks-kung-pao-chicken-mobile.html` is the mobile page as downloaded, with a comment added at the top.

These two files are available under CC BY-SA 4.0. This license applies only to them.

## Recipe sites (JSON-LD)

`bbcgoodfood-easy-pancakes.html`, `indianhealthyrecipes-chicken-curry.html`, `recipetineats-chow-mein.html`, `woksoflife-red-braised-pork-belly.html` and `woksoflife-shortcut-mongolian-ground-beef.html` are cut-down versions of the `schema.org/Recipe` data on the pages named in each file's first comment. They keep the structure the importer reads: titles, ingredient lists, yields, times, cuisine and image URLs. Reviews, ratings and author bios were removed. The descriptions and method steps were rewritten as short paraphrases that keep the timings and ingredients the tests depend on. The recipes belong to their sites.

## Other files

The `*-my-version*.txt` files are the app author's own recipe notes, used to test pasted text.
