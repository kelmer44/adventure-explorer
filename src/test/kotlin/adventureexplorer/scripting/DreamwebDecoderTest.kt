package adventureexplorer.scripting

import org.junit.Test
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File

class DreamwebDecoderTest {
    @Test fun `DreamWeb malformed resources and binary formats are bounded in LuaJ`() {
        JsePlatform.debugGlobals().loadfile(File("scripts/tests/dreamweb.lua").absolutePath).call()
    }
}
