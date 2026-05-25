package app.rxlab.rxcode.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.Shapes
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

private val LightColors = lightColorScheme(
    primary = Color(0xFF2457D6),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDCE4FF),
    onPrimaryContainer = Color(0xFF001A43),
    secondary = Color(0xFF006B5B),
    onSecondary = Color.White,
    secondaryContainer = Color(0xFF80F8DD),
    onSecondaryContainer = Color(0xFF00201A),
    tertiary = Color(0xFF7B5800),
    onTertiary = Color.White,
    tertiaryContainer = Color(0xFFFFDEA3),
    onTertiaryContainer = Color(0xFF281900),
    background = Color(0xFFFBF8FF),
    onBackground = Color(0xFF1B1B20),
    surface = Color(0xFFFBF8FF),
    onSurface = Color(0xFF1B1B20),
    surfaceVariant = Color(0xFFE2E2EC),
    onSurfaceVariant = Color(0xFF45464F),
    outline = Color(0xFF767680),
)

private val DarkColors = darkColorScheme(
    primary = Color(0xFFB6C4FF),
    onPrimary = Color(0xFF002C69),
    primaryContainer = Color(0xFF003F94),
    onPrimaryContainer = Color(0xFFDCE4FF),
    secondary = Color(0xFF5EDBC1),
    onSecondary = Color(0xFF00382F),
    secondaryContainer = Color(0xFF005044),
    onSecondaryContainer = Color(0xFF80F8DD),
    tertiary = Color(0xFFF3C04E),
    onTertiary = Color(0xFF412D00),
    tertiaryContainer = Color(0xFF5D4200),
    onTertiaryContainer = Color(0xFFFFDEA3),
    background = Color(0xFF121318),
    onBackground = Color(0xFFE4E2EA),
    surface = Color(0xFF121318),
    onSurface = Color(0xFFE4E2EA),
    surfaceVariant = Color(0xFF45464F),
    onSurfaceVariant = Color(0xFFC6C6D0),
    outline = Color(0xFF90909A),
)

private val RxCodeShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(14.dp),
    large = RoundedCornerShape(20.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

@Composable
fun RxCodeTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColors
        else -> LightColors
    }
    MaterialTheme(colorScheme = scheme, shapes = RxCodeShapes, content = content)
}
