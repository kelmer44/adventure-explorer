package adventureexplorer.scripting

import org.junit.Test
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File

class AsylumDecoderTest {
    @Test fun `Sanitarium archive frames palettes masks text and alignment are bounded in LuaJ`() {
        JsePlatform.debugGlobals().loadfile(File("scripts/tests/asylum.lua").absolutePath).call()
    }
}
