package com.vexguard.app.vpn

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal fun CoroutineScope.launchVpnControlOperation(
  onCompletion: () -> Unit,
  operation: suspend CoroutineScope.() -> Unit,
): Job = launch(block = operation).also { job ->
  // A canceled coroutine may never enter its body, including a finally block.
  // Bind watchdog cleanup to the job, which still completes in that case.
  job.invokeOnCompletion { onCompletion() }
}
