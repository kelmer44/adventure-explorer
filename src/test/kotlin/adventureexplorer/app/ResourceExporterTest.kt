package adventureexplorer.app

import adventureexplorer.model.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.launch
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import javax.sound.sampled.AudioSystem

class ResourceExporterTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun `same folder exports backgrounds across rooms without overwriting duplicate names`() = runBlocking {
        val image = BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB)
        File(temporary.root, "Background.png").writeText("existing")
        val tree = listOf(ResourceNode("rooms", "Rooms", "category", listOf(
            ResourceNode("room1", "Room 1", "category", listOf(
                ResourceNode("bg1", "Background", "image"),
                ResourceNode("script", "Script", "text")
            )),
            ResourceNode("room2", "Room 2", "category", listOf(
                ResourceNode("bg2", "background", "image")
            )),
            ResourceNode("empty", "Empty", "category")
        )))
        val loaded = mutableListOf<String>()
        val result = ResourceExporter({ node ->
            loaded += node.id
            ResourceData("image", image, null)
        }).export(ResourceCategories.filter(tree, ExportCategory.BACKGROUNDS), temporary.root, ExportLayout.SAME_FOLDER)
        assertEquals(2, result.exported)
        assertTrue(result.failures.isEmpty())
        assertEquals(listOf("bg1", "bg2"), loaded)
        assertEquals(setOf("Background.png", "Background (2).png", "background (3).png"), temporary.root.list()!!.toSet())
        assertEquals("existing", File(temporary.root, "Background.png").readText())
        assertEquals(2, ImageIO.read(File(temporary.root, "Background (2).png")).width)
        assertEquals(2, ImageIO.read(File(temporary.root, "background (3).png")).width)
    }

    @Test fun `same folder skips empty categories and keeps animation frames grouped and failure paths intact`() = runBlocking {
        val image = BufferedImage(2, 2, BufferedImage.TYPE_INT_RGB)
        val tree = listOf(ResourceNode("rooms", "Rooms", "category", listOf(
            ResourceNode("empty", "Empty", "category"),
            ResourceNode("animation", "Walk", "animation"),
            ResourceNode("bad", "Broken", "image")
        )))
        val result = ResourceExporter({ node ->
            if (node.id == "bad") null
            else ResourceData("animation", image, null, frames = listOf(image, image), frameDelayMs = 75)
        }).export(tree, temporary.root, ExportLayout.SAME_FOLDER)
        assertEquals(1, result.exported)
        assertEquals(1, result.failures.size)
        assertEquals(setOf("Walk", "export-errors.txt"), temporary.root.list()!!.toSet())
        assertTrue(File(temporary.root, "Walk/frame_0000.png").isFile)
        assertTrue(File(temporary.root, "Walk/frame_0001.png").isFile)
        assertTrue(File(temporary.root, "Walk/animation.txt").readText().contains("75 ms"))
        assertTrue(result.errorLog!!.readText().contains("/Rooms/Broken [bad]"))
    }

    @Test fun `model category exports rendered PNG instead of metadata`() = runBlocking {
        val node=ResourceNode("mesh","mesh","model")
        val model=ModelData(listOf(ModelVertex(-1.0,0.0,-1.0),ModelVertex(1.0,0.0,-1.0),ModelVertex(0.0,0.0,1.0)),
            listOf(ModelFace(listOf(0,1,2))),1)
        assertEquals(listOf(node),ResourceCategories.filter(listOf(node),ExportCategory.MODELS))
        val result=ResourceExporter({ ResourceData("model",null,"triangle",modelData=model) }).export(listOf(node),temporary.root)
        assertEquals(1,result.exported)
        val image=ImageIO.read(File(temporary.root,"mesh.png"))
        assertEquals(800,image.width)
        assertTrue(image.getRGB(0,0,800,600,null,0,800).distinct().size>1)
    }

    @Test fun `exports every decoded format within nested tree folders`() = runBlocking {
        val image = BufferedImage(256, 256, BufferedImage.TYPE_INT_RGB)
        image.setRGB(0, 0, 0x123456)
        val resources = linkedMapOf(
            "picture" to ResourceData("image", image, null),
            "animation" to ResourceData("animation", image, null, frames = listOf(image, image), frameDelayMs = 75),
            "sound" to ResourceData("sound", null, null, soundData = SoundData(byteArrayOf(0, 1, 2, 3), 8000, 8, 1, false)),
            "music" to ResourceData("midi", null, null, midiData = MidiData(byteArrayOf(77, 84, 104, 100))),
            "text" to ResourceData("text", null, null, textContent = "¡Hola!"),
            "metadata" to ResourceData("data", null, "Resource metadata"),
            "palette" to ResourceData("image", image, null)
        )
        val nodes = resources.map { (id, data) -> ResourceNode(id, id, if (id == "palette") "palette" else data.type) }
        val tree = listOf(ResourceNode("root", "Rooms", "category", listOf(
            ResourceNode("nested", "Room 1", "category", nodes),
            ResourceNode("empty", "Empty", "category")
        )))
        var released = 0
        val progress = mutableListOf<Int>()
        val result = ResourceExporter({ resources[it.id] }, { released++ }).export(tree, temporary.root) { index, total, _ ->
            assertEquals(7, total)
            progress += index
        }
        val folder = File(temporary.root, "Rooms/Room 1")
        assertEquals(7, result.exported)
        assertTrue(result.failures.isEmpty())
        assertNull(result.errorLog)
        assertEquals(7, released)
        assertEquals((1..7).toList(), progress)
        assertTrue(File(temporary.root, "Rooms/Empty").isDirectory)
        assertEquals(0x123456, ImageIO.read(File(folder, "picture.png")).getRGB(0, 0) and 0xffffff)
        assertTrue(File(folder, "animation/frame_0000.png").isFile)
        assertTrue(File(folder, "animation/frame_0001.png").isFile)
        assertTrue(File(folder, "animation/animation.txt").readText().contains("75 ms"))
        AudioSystem.getAudioInputStream(File(folder, "sound.wav")).use {
            assertEquals(8000f, it.format.sampleRate)
            assertArrayEquals(byteArrayOf(0, 1, 2, 3), it.readBytes())
        }
        assertArrayEquals(resources.getValue("music").midiData!!.bytes, File(folder, "music.mid").readBytes())
        assertEquals("¡Hola!", File(folder, "text.txt").readText())
        assertEquals("Resource metadata", File(folder, "metadata.txt").readText())
        assertArrayEquals(byteArrayOf(0x12, 0x34, 0x56), File(folder, "palette.bin").readBytes().take(3).toByteArray())
    }

    @Test fun `preserves existing files and disambiguates unsafe or duplicate names`() = runBlocking {
        File(temporary.root, "Same.txt").writeText("original")
        File(temporary.root, "Folder").mkdir()
        val names = listOf("same", "Same", "a/b", "a\\b", "..", "CON")
        val tree = names.mapIndexed { i, name -> ResourceNode("$i", name, "text") } +
            ResourceNode("folder", "folder", "category", listOf(ResourceNode("child", "Child", "text")))
        val result = ResourceExporter({ ResourceData("text", null, null, textContent = it.id) }).export(tree, temporary.root)
        assertEquals(7, result.exported)
        assertEquals("original", File(temporary.root, "Same.txt").readText())
        assertEquals("0", File(temporary.root, "same (2).txt").readText())
        assertEquals("1", File(temporary.root, "Same (3).txt").readText())
        assertEquals("2", File(temporary.root, "a_b.txt").readText())
        assertEquals("3", File(temporary.root, "a_b (2).txt").readText())
        assertEquals("4", File(temporary.root, "resource.txt").readText())
        assertEquals("5", File(temporary.root, "_CON.txt").readText())
        assertTrue(File(temporary.root, "folder (2)/Child.txt").isFile)
    }

    @Test fun `continues after failures and writes a report`() = runBlocking {
        val nodes = listOf("null", "exception", "empty", "ok").map { ResourceNode(it, it, "text") }
        var released = 0
        val result = ResourceExporter({
            when (it.id) {
                "null" -> null
                "exception" -> error("broken decoder")
                "empty" -> ResourceData("unknown", null, null)
                else -> ResourceData("text", null, null, textContent = "success")
            }
        }, { released++ }).export(nodes, temporary.root)
        assertEquals(1, result.exported)
        assertEquals(3, result.failures.size)
        assertEquals(4, released)
        assertTrue(result.errorLog!!.readText().contains("broken decoder"))
        assertEquals("success", File(temporary.root, "ok.txt").readText())
    }

    @Test fun `cancellation stops export and releases the resource`() = runBlocking {
        var released = false
        try {
            ResourceExporter({ throw CancellationException("cancelled") }, { released = true })
                .export(listOf(ResourceNode("cancel", "Cancel", "text")), temporary.root)
            fail("Expected cancellation")
        } catch (_: CancellationException) {
            assertTrue(released)
            assertTrue(temporary.root.list()!!.isEmpty())
        }
    }

    @Test fun `stopping during decode keeps completed files and skips remaining resources`() = runBlocking {
        val loaded = mutableListOf<String>()
        var released = 0
        val job = launch {
            val runningJob = currentCoroutineContext()[Job]!!
            ResourceExporter({ node ->
                loaded += node.id
                if (node.id == "stop") runningJob.cancel()
                ResourceData("text", null, null, textContent = node.id)
            }, { released++ }).export(
                listOf("first", "stop", "last").map { ResourceNode(it, it, "text") }, temporary.root
            )
        }
        job.join()
        assertTrue(job.isCancelled)
        assertEquals(listOf("first", "stop"), loaded)
        assertEquals(2, released)
        assertEquals("first", File(temporary.root, "first.txt").readText())
        assertFalse(File(temporary.root, "stop.txt").exists())
        assertFalse(File(temporary.root, "last.txt").exists())
    }

    @Test fun `exports selected subtree without siblings or ancestors`() = runBlocking {
        val selected = ResourceNode("selected", "Selected folder", "category", listOf(
            ResourceNode("nested", "Nested", "category", listOf(ResourceNode("leaf", "Leaf", "text")))
        ))
        val result = ResourceExporter({ ResourceData("text", null, null, textContent = it.id) })
            .export(listOf(selected), temporary.root)
        assertEquals(1, result.exported)
        assertEquals(listOf("Selected folder"), temporary.root.list()!!.toList())
        assertEquals("leaf", File(temporary.root, "Selected folder/Nested/Leaf.txt").readText())
    }
}
