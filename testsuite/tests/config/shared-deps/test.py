"""
Check that globally sharing builds works as expected
"""

import glob
import os

from drivers.alr import (alr_builds_dir, alr_vault_dir, alr_with, alr_workspace_cache,
                         init_local_crate, run_alr)
from drivers.asserts import assert_contents, assert_file_exists
from drivers.helpers import lines_of

vault_dir = alr_vault_dir()
build_dir = alr_builds_dir()

# Enable shared builds
run_alr("config", "--global", "--set", "dependencies.shared", "true")

# Create a crate with a dependency
init_local_crate()
alr_with("hello")

# Ensure the "read-only" sources are where expected
assert_file_exists(os.path.join(vault_dir, "hello_1.0.1_filesystem"))
assert_file_exists(os.path.join(vault_dir, "libhello_1.0.0_filesystem"))

# Check contents of one of the dependencies to make even surer
assert_contents(base := os.path.join(vault_dir, "hello_1.0.1_filesystem"),
                [f'{base}/alire',
                 f'{base}/alire.toml',
                 f'{base}/alire/complete_copy',
                 f'{base}/hello.gpr',
                 f'{base}/src',
                 f'{base}/src/hello.adb'])

# Check the contents in the build dir, that should include generated configs

# We need to find the hash first
base = glob.glob(os.path.join(build_dir, "hello_1.0.1_filesystem_*"))[0]

assert_contents(base,
                [f'{base}/alire',
                 f'{base}/alire.toml',
                 f'{base}/alire/complete_copy',
                 f'{base}/config',
                 f'{base}/config/hello_config.ads',
                 f'{base}/config/hello_config.gpr',
                 f'{base}/config/hello_config.h',
                 f'{base}/hello.gpr',
                 f'{base}/src',
                 f'{base}/src/hello.adb'])

# And that the crate usual cache dir doesn't exist
assert not os.path.exists(alr_workspace_cache())

# Import the dependency in our code to ensure build works with the new cache
# location
new_code = ["with Hello;\n"] + lines_of(os.path.join("src", "xxx.adb"))
with open(os.path.join("src", "xxx.adb"), "w") as f:
    f.writelines(new_code)

run_alr("build")


print('SUCCESS')
