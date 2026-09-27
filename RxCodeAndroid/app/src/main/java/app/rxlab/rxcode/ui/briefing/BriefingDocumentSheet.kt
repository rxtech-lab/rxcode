package app.rxlab.rxcode.ui.briefing

import android.text.Html
import java.io.File
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.rxlab.rxcode.proto.MobileBriefingAsset
import app.rxlab.rxcode.proto.MobileBriefingDocument
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.ui.util.RxMarkdownText

@Composable
fun BriefingDocumentSheet(
    document: MobileBriefingDocument,
    state: MobileState,
    viewModel: MobileAppState,
) {
    val context = LocalContext.current
    var content by remember(document.id) { mutableStateOf<String?>(null) }
    var assets by remember(document.id) { mutableStateOf<List<MobileBriefingAsset>>(emptyList()) }
    var error by remember(document.id) { mutableStateOf<String?>(null) }
    var selectedAsset by remember(document.id) { mutableStateOf<MobileBriefingAsset?>(null) }
    val saveFile = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri != null) {
            try {
                val path = state.briefingAssetFilePath ?: throw IllegalStateException("The file is unavailable.")
                val output = context.contentResolver.openOutputStream(uri)
                    ?: throw IllegalStateException("Unable to create the selected file.")
                output.use {
                    File(path).inputStream().use { input -> input.copyTo(it) }
                }
            } catch (failure: Exception) {
                error = failure.localizedMessage ?: "Unable to save the file."
            }
        }
    }

    LaunchedEffect(document.id, document.updatedAt) {
        content = null
        assets = emptyList()
        error = null
        viewModel.requestBriefingContent(document.id)
    }
    LaunchedEffect(state.briefingContentResult?.clientRequestID) {
        val result = state.briefingContentResult ?: return@LaunchedEffect
        if (result.briefingID != document.id) return@LaunchedEffect
        if (result.assetPath == null) {
            if (result.ok) {
                content = result.content.orEmpty()
                assets = result.assets.orEmpty()
            } else {
                error = result.errorMessage ?: "The briefing is unavailable."
            }
        } else if (result.assetPath == selectedAsset?.path) {
            error = if (result.ok && state.briefingAssetFilePath != null) null
                else result.errorMessage ?: "The file is unavailable."
        }
    }

    Column(
        Modifier.fillMaxWidth().heightIn(max = 700.dp).verticalScroll(rememberScrollState()).padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(document.title, style = MaterialTheme.typography.headlineSmall)
        when {
            content != null && document.format == "html" -> Text(
                Html.fromHtml(content.orEmpty(), Html.FROM_HTML_MODE_COMPACT).toString(),
                style = MaterialTheme.typography.bodyMedium,
            )
            content != null -> RxMarkdownText(markdown = content.orEmpty())
            error != null -> Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
            else -> CircularProgressIndicator()
        }
        if (assets.isNotEmpty()) {
            HorizontalDivider()
            Text("Files", style = MaterialTheme.typography.titleMedium)
            assets.forEach { asset ->
                Button(onClick = {
                    selectedAsset = asset
                    error = null
                    viewModel.requestBriefingContent(document.id, asset.path)
                }) { Text(asset.path) }
            }
        }
        if (selectedAsset != null) {
            when {
                state.isLoadingBriefingContent -> CircularProgressIndicator()
                state.briefingAssetFilePath != null -> Button(onClick = {
                    saveFile.launch(selectedAsset!!.path.substringAfterLast('/'))
                }) { Text("Save ${selectedAsset!!.path.substringAfterLast('/')}") }
                error != null -> Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
            }
        }
    }
}
