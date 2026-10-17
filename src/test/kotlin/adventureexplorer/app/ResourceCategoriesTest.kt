package adventureexplorer.app

import adventureexplorer.model.ExportCategory
import adventureexplorer.model.ResourceCategories
import adventureexplorer.model.ResourceNode
import org.junit.Assert.*
import org.junit.Test

class ResourceCategoriesTest {
    private val background = ResourceNode("room_bg_1", "Background", "image")
    private val sprite = ResourceNode("cost:1", "Costume", "animation")
    private val palette = ResourceNode("pal_1", "Background palette", "palette")
    private val tree = listOf(
        ResourceNode("rooms", "Rooms", "category", listOf(
            ResourceNode("room_1", "Room 1", "category", listOf(background, palette,
                ResourceNode("notes", "Background notes", "text"))),
            ResourceNode("room_2", "Room 2", "category", listOf(ResourceNode("empty", "Empty", "category")))
        )),
        ResourceNode("actors", "Sprites & Animations", "category", listOf(sprite,
            ResourceNode("pixels", "Frame", "image"))),
        ResourceNode("anim", "Intro", "animation"),
        ResourceNode("icon", "Inventory icon", "image"),
        ResourceNode("sfx", "Sound effect", "sound"),
        ResourceNode("song", "Song", "midi"),
        ResourceNode("raw", "Raw data", "data")
    )

    @Test fun `category counts use types and inherit background and sprite roles`() {
        val counts = ResourceCategories.counts(tree)
        assertEquals(1, counts[ExportCategory.BACKGROUNDS])
        assertEquals(2, counts[ExportCategory.SPRITES])
        assertEquals(2, counts[ExportCategory.ANIMATIONS])
        assertEquals(3, counts[ExportCategory.IMAGES])
        assertEquals(1, counts[ExportCategory.PALETTES])
        assertEquals(1, counts[ExportCategory.SOUNDS])
        assertEquals(1, counts[ExportCategory.MUSIC])
        assertEquals(1, counts[ExportCategory.TEXT])
        assertEquals(1, counts[ExportCategory.DATA])
    }

    @Test fun `filter retains only matching leaves and their ancestor hierarchy`() {
        val filtered = ResourceCategories.filter(tree, ExportCategory.BACKGROUNDS)
        assertEquals(1, filtered.size)
        assertEquals("rooms", filtered.single().id)
        val room = filtered.single().children.single()
        assertEquals("room_1", room.id)
        assertEquals(listOf(background), room.children)
        assertEquals(2, tree.first().children.size)
        assertEquals(3, tree.first().children.first().children.size)
    }

    @Test fun `sprite animations appear in both relevant categories`() {
        val sprites = ResourceCategories.filter(tree, ExportCategory.SPRITES)
        assertEquals(listOf(sprite, tree[1].children[1]), sprites.single().children)
        val animations = ResourceCategories.filter(tree, ExportCategory.ANIMATIONS)
        assertEquals(listOf(sprite), animations.first().children)
        assertEquals("anim", animations.last().id)
    }

    @Test fun `roles are inferred from folder labels and delimited identifiers`() {
        val nodes = listOf(
            ResourceNode("backgrounds", "Room views", "category", listOf(ResourceNode("1", "Room", "image"))),
            ResourceNode("spr_2", "Frame", "image"),
            ResourceNode("object", "A sprite", "image"),
            ResourceNode("diagram", "BackgroundSprite diagram", "image")
        )
        assertEquals(1, ResourceCategories.counts(nodes)[ExportCategory.BACKGROUNDS])
        assertEquals(2, ResourceCategories.counts(nodes)[ExportCategory.SPRITES])
        assertTrue(ResourceCategories.filter(nodes, ExportCategory.SOUNDS).isEmpty())
        assertTrue(ResourceCategories.counts(emptyList()).isEmpty())
    }
}
