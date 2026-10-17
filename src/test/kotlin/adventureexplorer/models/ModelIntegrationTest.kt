package adventureexplorer.models

import adventureexplorer.model.*
import adventureexplorer.scripting.ScriptManager
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

class ModelIntegrationTest {
    @Test fun `all local Grim models decode and render`() = scan("GRIM_MODEL_TEST_PATH", "grim")
    @Test fun `all local City models decode and render`() = scan("CITY_MODEL_TEST_PATH", "city")
    @Test fun `all local Alone 1 bodies decode and render`() = scan("AITD1_MODEL_TEST_PATH", "aitd")
    @Test fun `all local Alone 2 bodies decode and render`() = scan("AITD2_MODEL_TEST_PATH", "aitd")
    @Test fun `all local Alone 3 bodies decode and render`() = scan("AITD3_MODEL_TEST_PATH", "aitd")
    private fun scan(variable: String, engineId: String) {
        val path=System.getenv(variable)
        assumeTrue("Set $variable to test installed assets", path!=null)
        val mgr=ScriptManager()
        try {
            val game=mgr.detectGame(path!!)!!
            assertEquals(engineId,game.engineId)
            fun leaves(nodes: List<ResourceNode>): List<ResourceNode> = nodes.flatMap { if(it.isCategory) leaves(it.children) else listOf(it) }
            val models=leaves(game.resources).filter { it.type=="model" }
            assertTrue(models.isNotEmpty())
            val failures=mutableListOf<String>()
            for (node in models) {
                val data=mgr.loadResource(path,node.id)
                val model=data?.modelData
                if (model==null && data?.textContent?.contains("Model has no visible geometry") != true) failures += "${node.name}: ${data?.textContent}"
                else if (model!=null) {
                    val image=ModelRenderer.render(model,160,120)
                    assertEquals(160,image.width)
                    if (node.name in listOf("manny.3do","manny_deathrobe.3do","CIMIET.TMM","BATONP.TMM") || (engineId=="aitd" && node.id.endsWith("_0"))) {
                        val out=File("build/model-previews"); out.mkdirs()
                        javax.imageio.ImageIO.write(ModelRenderer.render(model),"png",File(out,File(path).name+"_"+node.id.replace('/','_')+".png"))
                    }
                }
                mgr.releaseDecodedResources()
            }
            println("$engineId: ${models.size} models; ${failures.size} failures")
            assertTrue(failures.joinToString("\n"),failures.isEmpty())
        } finally { mgr.close() }
    }
}
