// Standalone KAT (known-answer test) for XNNPACK, built by mayhem/build.sh against a NORMAL
// (unsanitized) build of the library. It exercises a real computation through the public API
// (xnn_run_binary_elementwise_nd, f32 element-wise add) with fixed inputs and prints the computed
// outputs so mayhem/test.sh can assert them against hand-computed expected values. This is a real
// behavioral oracle: a source patch that no-ops the computation (or a sabotage LD_PRELOAD that
// _exit(0)s the binary before it prints) makes the expected "KAT_OUTPUT: ..." line disappear.
#include <cstdio>
#include <cstdlib>

#include <xnnpack.h>

int main() {
  xnn_status status = xnn_initialize(nullptr);
  if (status != xnn_status_success) {
    fprintf(stderr, "xnn_initialize failed: %d\n", status);
    return 1;
  }

  const size_t n = 4;
  float input1[4] = {1.0f, 2.0f, 3.0f, 4.0f};
  float input2[4] = {10.0f, 20.0f, 30.0f, 40.0f};
  float output[4] = {0};

  const size_t shape[1] = {n};

  status = xnn_run_binary_elementwise_nd(
      xnn_binary_add, xnn_datatype_fp32,
      /*input1_quantization=*/nullptr, /*input2_quantization=*/nullptr,
      /*output_quantization=*/nullptr, /*flags=*/0,
      /*num_input1_dims=*/1, shape, /*num_input2_dims=*/1, shape,
      input1, input2, output, /*threadpool=*/nullptr);

  xnn_deinitialize();

  if (status != xnn_status_success) {
    fprintf(stderr, "xnn_run_binary_elementwise_nd failed: %d\n", status);
    return 1;
  }

  printf("KAT_OUTPUT: %.1f,%.1f,%.1f,%.1f\n", output[0], output[1], output[2],
         output[3]);
  return 0;
}
