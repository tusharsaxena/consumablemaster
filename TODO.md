# TODO

- ✅ Increase the spacing between the item name label and the icons to its right.
- ✅ Add a draggable macro icon at the top of each category panel (below the title) so users can drag the macro onto an action bar.
- ✅ Consolidate the per-category Stat Priority section into a single shared "Stat Priority" panel. Move the "Viewing spec" dropdown there. Place the new section directly below the General tab in the tab selector.
- ✅ Move the sub text :Spec-aware. Viewing 12_581" to be just below the title and above the macro drag icon row. Add some row spacing between this text and macro selector.
- ✅ Replace spec-id strings (e.g. `7_264`) with the actual class and spec names, optionally with class/spec icons.
- ✅ In the General tab: move "Force resync" to the second line and "Reset all priorities" to the third line. Remove the version number.
- ✅ Add a `/kcm version` slash command that prints the addon version.
- ✅ Change the delete button glyph from a red X (collides with the "not in bags" icon) to a different glyph — i would suggest a red circle with a diagonal line through it (no-entry sign).
- ✅ Check the Stat Food section — formatting looks off. The separator and reset category and stat priority sections appear midway through the list - the list is long. screenshot here: https://i.ibb.co/rK5MpPys/Untitled.png and https://i.ibb.co/VcQPT7NG/image.png
- ✅ Check default seed items again once - remove classic fallbacks and use items from midnight silvermoon innkeeper as seed items - ask the user for which items should be a part of the seed list.
- ✅ relook into the .md files which has instructions on how to build the seed lists
- ✅ Add conjured food and recuperate to the seed list. Recuperate (spell id: 1231411) should be the top ranked item in food in the seed list, unless manually overriden (removed and order dropped) by the user. Conjured food (Conjured Mana Bun, item id 113509) should by default be the second item in the food category and top item in the drink categry; unless deleted or order changed by the user
- ✅ Simplify the dump commands
- ✅ Rename the entry in the Settings Panel to be Consumable Master instead of Ka0s Consumable Master. The addon name should be retained as Ka0s Consumable Master though. Do not rename the directory name. 
- ✅ Add the ability to add an item or spell to each category. Achieve this by having a dropdown to select Item or Spell to the left of the inputbox. Add a validator to check whether a valid itemid or spellid has been entered. 
- ✅ Add a confirmation dialog before adding an item or spell
- ⬜ Add stat weights alongside stat priorities for primary and secondary stats to better improve ranking
- ⬜ for every item, add a checkbox to disable a specific item from being picked by the macro. this will allow the user to preserve ordering without deleting the item altogether
