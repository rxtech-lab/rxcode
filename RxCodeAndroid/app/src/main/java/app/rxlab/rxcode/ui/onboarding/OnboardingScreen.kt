package app.rxlab.rxcode.ui.onboarding

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.CameraAlt
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.LifecycleOwner
import app.rxlab.rxcode.pairing.PairingToken
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.state.MobileState
import app.rxlab.rxcode.state.PairingStatus
import app.rxlab.rxcode.ui.util.HapticEvent
import app.rxlab.rxcode.ui.util.rememberHaptics
import com.google.accompanist.permissions.ExperimentalPermissionsApi
import com.google.accompanist.permissions.isGranted
import com.google.accompanist.permissions.rememberPermissionState
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.util.concurrent.Executors

/** Pair-with-Mac screen: device name, camera scanner, and photo QR fallback. */
@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class)
@Composable
fun OnboardingScreen(
    state: MobileState,
    viewModel: MobileAppState,
    onDismiss: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    var scannerOpen by remember { mutableStateOf(false) }
    var scanOptionsOpen by remember { mutableStateOf(false) }
    var localError by remember { mutableStateOf<String?>(null) }
    var displayName by remember {
        mutableStateOf(Build.MODEL.ifBlank { "Android" })
    }
    val effectiveDisplayName = displayName.trim().ifBlank { Build.MODEL.ifBlank { "Android" } }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
        if (uri != null) {
            pairingLog("photo QR selected: $uri")
            decodeQrFromImageUri(
                context = context,
                uri = uri,
                onRawValue = { raw ->
                    pairingLog("photo QR decoded (${raw.length} chars)")
                    val token = PairingToken.parseOrNull(raw)
                    if (token == null) {
                        Log.w(TAG, "photo QR rejected: not an RxCode pairing token")
                        localError = "Unrecognized QR. Try scanning the one from the Mac app."
                    } else {
                        pairingLog("photo QR accepted: ${token.logSummary()}")
                        localError = null
                        viewModel.beginPairing(token, effectiveDisplayName)
                    }
                },
                onError = { message -> localError = message },
            )
        } else {
            pairingLog("photo QR picker returned no image")
        }
    }

    LaunchedEffect(Unit) {
        pairingLog("OnboardingScreen visible; paired=${state.isPaired}")
    }

    LaunchedEffect(state.isPaired) {
        if (state.isPaired) {
            pairingLog("pairing completed; closing scanner")
            scannerOpen = false
        }
    }

    val haptics = rememberHaptics()
    if (scannerOpen) {
        PairingCameraScreen(
            pairing = state.pairing,
            onDismiss = {
                viewModel.clearPairingError()
                scannerOpen = false
            },
            onToken = { token ->
                haptics.play(HapticEvent.LightTap)
                scannerOpen = false
                localError = null
                viewModel.beginPairing(token, effectiveDisplayName)
            },
            onRetry = viewModel::clearPairingError,
        )
        return
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            if (onDismiss != null) {
                CenterAlignedTopAppBar(
                    title = { Text("Pair with your Mac") },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                        }
                    },
                )
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 28.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(16.dp))
            Surface(
                modifier = Modifier.size(112.dp),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                tonalElevation = 6.dp,
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.Devices, contentDescription = null, modifier = Modifier.size(48.dp))
                }
            }
            Column(
                verticalArrangement = Arrangement.spacedBy(6.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    "Pair with your Mac",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "Securely link this device to RxCode in seconds.",
                    style = MaterialTheme.typography.bodyLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            PairingInstructions()

            DeviceNameField(
                value = displayName,
                onValueChange = { displayName = it },
                onClear = { displayName = "" },
            )

            PairingStatusCard(state.pairing, onDismiss = viewModel::clearPairingError)
            localError?.let {
                ErrorBanner(message = it, onDismiss = { localError = null })
            }

            Button(
                onClick = { scanOptionsOpen = true },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Outlined.QrCodeScanner, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Scan QR Code")
            }
        }
    }

    if (scanOptionsOpen) {
        ScanOptionsSheet(
            onDismiss = { scanOptionsOpen = false },
            onCamera = {
                pairingLog("opening camera QR scanner")
                scanOptionsOpen = false
                scannerOpen = true
            },
            onPhotos = {
                pairingLog("opening photo QR picker")
                scanOptionsOpen = false
                photoPicker.launch("image/*")
            },
        )
    }
}

@Composable
private fun PairingInstructions() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            StepRow(number = 1, text = "Open RxCode on your Mac.")
            StepRow(number = 2, text = "Go to Settings > Mobile and tap Pair new device.")
            StepRow(number = 3, text = "Scan the QR code shown on your Mac with this app.")
        }
    }
}

@Composable
private fun StepRow(number: Int, text: String) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        Surface(
            shape = CircleShape,
            color = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
            modifier = Modifier.size(28.dp),
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(number.toString(), style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
            }
        }
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun DeviceNameField(
    value: String,
    onValueChange: (String) -> Unit,
    onClear: () -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            "Device name",
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = {
                Icon(Icons.Outlined.Devices, contentDescription = null)
            },
            trailingIcon = {
                if (value.isNotEmpty()) {
                    IconButton(onClick = onClear) {
                        Icon(Icons.Outlined.Close, contentDescription = "Clear device name")
                    }
                }
            },
            placeholder = { Text("Device name") },
        )
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Outlined.Close, contentDescription = "Dismiss")
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScanOptionsSheet(
    onDismiss: () -> Unit,
    onCamera: () -> Unit,
    onPhotos: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add a QR code", style = MaterialTheme.typography.titleLarge)
            Text(
                "Scan the QR code shown on your Mac, or pick a screenshot from your library.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(onClick = onCamera, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.CameraAlt, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Scan with Camera")
            }
            FilledTonalButton(onClick = onPhotos, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.Image, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Choose from Photos")
            }
            TextButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth()) {
                Text("Cancel")
            }
            Spacer(Modifier.height(12.dp))
        }
    }
}

@Composable
private fun PairingStatusCard(pairing: PairingStatus, onDismiss: () -> Unit) {
    when (pairing) {
        PairingStatus.Idle -> Unit
        PairingStatus.InProgress -> Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Pairing in progress", style = MaterialTheme.typography.titleMedium)
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            }
        }
        is PairingStatus.Failed -> Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
        ) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Pairing failed", style = MaterialTheme.typography.titleMedium)
                Text(pairing.message, style = MaterialTheme.typography.bodyMedium)
                OutlinedButton(onClick = onDismiss) { Text("Dismiss") }
            }
        }
    }
}

@OptIn(ExperimentalPermissionsApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun PairingCameraScreen(
    pairing: PairingStatus,
    onDismiss: () -> Unit,
    onToken: (PairingToken) -> Unit,
    onRetry: () -> Unit,
) {
    val camPermission = rememberPermissionState(android.Manifest.permission.CAMERA)
    var scanLocked by remember { mutableStateOf(false) }
    var scannerKey by remember { mutableStateOf(0) }
    var scanError by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(camPermission.status.isGranted) {
        pairingLog("camera permission granted=${camPermission.status.isGranted}")
    }

    Scaffold(
        containerColor = Color.Black,
        topBar = {
            CenterAlignedTopAppBar(
                title = { Text("Scan pairing QR") },
                navigationIcon = {
                    IconButton(onClick = onDismiss) {
                        Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .background(Color.Black),
        ) {
            val scannerActive = camPermission.status.isGranted && !scanLocked && pairing !is PairingStatus.InProgress
            if (camPermission.status.isGranted) {
                QRCameraPreview(
                    modifier = Modifier.fillMaxSize(),
                    scanKey = scannerKey,
                    enabled = scannerActive,
                    onToken = { token ->
                        pairingLog("camera QR accepted: ${token.logSummary()}")
                        scanLocked = true
                        scanError = null
                        onToken(token)
                    },
                    onInvalidQr = {
                        if (!scanLocked) {
                            Log.w(TAG, "camera QR rejected: not an RxCode pairing token")
                            scanError = "That QR code is not an RxCode pairing code."
                        }
                    },
                )
                CameraShade()
                Box(
                    modifier = Modifier
                        .align(Alignment.Center)
                        .size(252.dp)
                        .border(3.dp, MaterialTheme.colorScheme.primary, RoundedCornerShape(28.dp)),
                )
            } else {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(
                        Icons.Outlined.QrCodeScanner,
                        contentDescription = null,
                        modifier = Modifier.size(56.dp),
                        tint = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.height(16.dp))
                    Text("Camera access is required to scan the pairing QR.")
                    Spacer(Modifier.height(16.dp))
                    Button(onClick = { camPermission.launchPermissionRequest() }) {
                        Text("Allow camera access")
                    }
                }
            }

            PairingCameraStatus(
                pairing = pairing,
                scanError = scanError,
                scanning = scannerActive,
                onRetry = {
                    pairingLog("retrying camera QR scan")
                    onRetry()
                    scanError = null
                    scanLocked = false
                    scannerKey += 1
                },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(16.dp),
            )
        }
    }
}

@Composable
private fun CameraShade() {
    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    0f to Color.Black.copy(alpha = 0.58f),
                    0.36f to Color.Transparent,
                    0.64f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.72f),
                )
            )
    )
}

@Composable
private fun PairingCameraStatus(
    pairing: PairingStatus,
    scanError: String?,
    scanning: Boolean,
    onRetry: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(28.dp),
        tonalElevation = 6.dp,
        color = MaterialTheme.colorScheme.surface,
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            when (pairing) {
                PairingStatus.Idle -> {
                    if (scanning) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Outlined.QrCodeScanner, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                            Spacer(Modifier.width(10.dp))
                            Text("Scanning…", style = MaterialTheme.typography.titleMedium)
                        }
                        Text(
                            "Position the QR code inside the frame.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        scanError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    } else {
                        Text("Position the QR code inside the frame.", style = MaterialTheme.typography.titleMedium)
                        scanError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                    }
                }
                PairingStatus.InProgress -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                        Spacer(Modifier.width(10.dp))
                        Text("QR detected. Waiting for your Mac…", style = MaterialTheme.typography.titleMedium)
                    }
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
                is PairingStatus.Failed -> {
                    Text("Pairing failed", style = MaterialTheme.typography.titleMedium)
                    Text(pairing.message, style = MaterialTheme.typography.bodyMedium)
                    FilledTonalButton(onClick = onRetry, modifier = Modifier.fillMaxWidth()) {
                        Text("Scan again")
                    }
                }
            }
        }
    }
}

@Composable
private fun QRCameraPreview(
    modifier: Modifier = Modifier,
    scanKey: Int,
    enabled: Boolean,
    onToken: (PairingToken) -> Unit,
    onInvalidQr: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val enabledState = rememberUpdatedState(enabled)
    val previewView = remember(context) {
        PreviewView(context).apply {
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
    }

    AndroidView(
        modifier = modifier,
        factory = { previewView },
    )

    DisposableEffect(context, lifecycleOwner, previewView, scanKey) {
        val cameraBinding = bindCamera(
            context = context,
            owner = lifecycleOwner,
            previewView = previewView,
            enabled = { enabledState.value },
            onToken = onToken,
            onInvalidQr = onInvalidQr,
        )
        onDispose { cameraBinding.dispose() }
    }
}

private class CameraBinding(
    private val disposeAction: () -> Unit,
) {
    fun dispose() = disposeAction()
}

private fun bindCamera(
    context: Context,
    owner: LifecycleOwner,
    previewView: PreviewView,
    enabled: () -> Boolean,
    onToken: (PairingToken) -> Unit,
    onInvalidQr: () -> Unit,
): CameraBinding {
    pairingLog("binding camera scanner")
    val providerFuture = ProcessCameraProvider.getInstance(context)
    val mainExecutor = androidx.core.content.ContextCompat.getMainExecutor(context)
    val executor = Executors.newSingleThreadExecutor()
    var provider: ProcessCameraProvider? = null
    var scanner: BarcodeScanner? = null
    var disposed = false
    providerFuture.addListener({
        if (disposed) return@addListener
        provider = runCatching { providerFuture.get() }
            .onFailure { Log.e(TAG, "camera provider failed: ${it.message}", it) }
            .getOrNull()
            ?: return@addListener
        val preview = Preview.Builder().build().apply {
            setSurfaceProvider(previewView.surfaceProvider)
        }
        val scannerOptions = BarcodeScannerOptions.Builder()
            .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
            .build()
        scanner = BarcodeScanning.getClient(scannerOptions)
        pairingLog("ML Kit QR scanner created")
        val analysisResolution = ResolutionSelector.Builder()
            .setResolutionStrategy(
                ResolutionStrategy(
                    Size(1280, 720),
                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                )
            )
            .build()
        val analysis = ImageAnalysis.Builder()
            .setResolutionSelector(analysisResolution)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .build()
        var lastSeen: String? = null
        var reportedInvalid = false
        var analyzedFrames = 0
        var disabledFrames = 0
        analysis.setAnalyzer(executor) { proxy: ImageProxy ->
            if (!enabled()) {
                disabledFrames += 1
                if (disabledFrames == 1) {
                    pairingLog("camera analyzer paused while pairing is in progress or scan is locked")
                }
                proxy.close()
                return@setAnalyzer
            }
            disabledFrames = 0
            analyzedFrames += 1
            val mediaImage = proxy.image
            if (mediaImage == null) {
                if (analyzedFrames == 1 || analyzedFrames % 90 == 0) {
                    Log.w(TAG, "camera frame has no image (frames=$analyzedFrames)")
                }
                proxy.close()
                return@setAnalyzer
            }
            val input = InputImage.fromMediaImage(mediaImage, proxy.imageInfo.rotationDegrees)
            val activeScanner = scanner
            if (activeScanner == null) {
                Log.w(TAG, "camera analyzer has no active barcode scanner")
                proxy.close()
                return@setAnalyzer
            }
            activeScanner.process(input)
                .addOnSuccessListener(mainExecutor) { barcodes ->
                    val qrValues = barcodes
                        .filter { it.format == Barcode.FORMAT_QR_CODE }
                        .mapNotNull { it.rawValue }
                    if (qrValues.isEmpty()) {
                        if (analyzedFrames % 90 == 0) {
                            pairingLog("camera scanner active; no QR found yet (frames=$analyzedFrames)")
                        }
                    } else {
                        pairingLog("camera scanner found ${barcodes.size} barcode(s), ${qrValues.size} raw value(s)")
                    }
                    qrValues.firstOrNull { it != lastSeen }?.let { raw ->
                        lastSeen = raw
                        pairingLog("camera QR decoded (${raw.length} chars)")
                        val token = PairingToken.parseOrNull(raw)
                        if (token != null) {
                            reportedInvalid = false
                            onToken(token)
                        } else if (!reportedInvalid) {
                            reportedInvalid = true
                            onInvalidQr()
                        }
                    }
                }
                .addOnFailureListener(mainExecutor) { error ->
                    Log.w(TAG, "camera QR processing failed: ${error.message}", error)
                }
                .addOnCompleteListener { proxy.close() }
        }
        provider?.unbindAll()
        runCatching {
            provider?.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        }.onSuccess {
            pairingLog("camera scanner bound to lifecycle")
        }.onFailure {
            Log.e(TAG, "camera scanner bind failed: ${it.message}", it)
        }
    }, mainExecutor)

    return CameraBinding {
        pairingLog("disposing camera scanner")
        disposed = true
        provider?.unbindAll()
        scanner?.close()
        executor.shutdown()
    }
}

private fun decodeQrFromImageUri(
    context: Context,
    uri: Uri,
    onRawValue: (String) -> Unit,
    onError: (String) -> Unit,
) {
    pairingLog("decoding QR from selected image: $uri")
    val scanner = BarcodeScanning.getClient()
    val input = runCatching { InputImage.fromFilePath(context, uri) }
        .getOrElse {
            Log.w(TAG, "selected image could not be read: ${it.message}", it)
            scanner.close()
            onError("Couldn't read the selected image.")
            return
        }
    scanner.process(input)
        .addOnSuccessListener { barcodes ->
            val value = barcodes
                .firstOrNull { it.format == Barcode.FORMAT_QR_CODE || it.rawValue != null }
                ?.rawValue
            if (value == null) {
                Log.w(TAG, "selected image contains no QR code (barcodes=${barcodes.size})")
                onError("No QR code found in that image.")
            } else {
                pairingLog("selected image contains QR (${value.length} chars)")
                onRawValue(value)
            }
        }
        .addOnFailureListener {
            Log.w(TAG, "selected image QR scan failed: ${it.message}", it)
            onError("Couldn't load the selected image.")
        }
        .addOnCompleteListener {
            scanner.close()
        }
}

private fun PairingToken.logSummary(): String =
    "desktop=${desktopName.ifBlank { "unknown" }}, relay=${relayURL}, desktopPubkey=${desktopPubkeyHex.take(12)}, expiresAt=$expiresAt, expired=$isExpired"

private fun pairingLog(message: String) {
    Log.w(TAG, message)
}

private const val TAG = "OnboardingScreen"
