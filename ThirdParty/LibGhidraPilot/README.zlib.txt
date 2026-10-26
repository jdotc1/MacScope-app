libghidra 0.0.2's native local backend incorporates Ghidra decompiler/runtime
components whose distributed dependency set includes zlib-licensed code.

MacScope does not vendor or modify that implementation code in DCP-03B3. The
adjacent `LICENSE.zlib.txt` preserves the applicable zlib 1.3.1 notice. The
approved wheel is materialized only by the explicit checksum-verifying developer
script into the ignored `libghidra-dcp03b3/` environment; it is not acquired by
ordinary build or test paths and is not shipped in any MacScope target.
