package adventureexplorer.scripting

import org.junit.Test
import org.luaj.vm2.lib.jse.JsePlatform
import java.io.File

class LegacyEngineDecoderTest {
    @Test fun `Curse planar sprites and PCM reject malformed inputs under LuaJ`() {
        JsePlatform.debugGlobals().loadfile(File("scripts/tests/curseofenchantia.lua").absolutePath).call()
    }

    @Test fun `SCUMM V2 dither masks and room tables are bounded under LuaJ`() {
        JsePlatform.debugGlobals().loadfile(File("scripts/tests/scumm_v2.lua").absolutePath).call()
    }
}
