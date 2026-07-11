# Toolchain image for the calculator project.
# Provides every prerequisite listed in calculator/README.md:
#   - GNU C++17 compiler (g++ via build-essential)
#   - GoogleTest unit test library (built into /usr/local)
#   - clang-tidy
#   - clang-format
FROM ubuntu:24.04

# Avoid interactive prompts during apt installs
ENV DEBIAN_FRONTEND=noninteractive

# Install the toolchain prerequisites
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        make \
        cmake \
        libgtest-dev \
        clang-tidy \
        clang-format \
    && rm -rf /var/lib/apt/lists/*

# Build GoogleTest and install the static libs where the Makefiles expect them
# (tests/Makefile uses GTEST_DIR=/usr/local/include/gtest, GTEST_LIB_DIR=/usr/local/lib).
RUN cmake -S /usr/src/googletest -B /tmp/gtest-build \
    && cmake --build /tmp/gtest-build --target install \
    && rm -rf /tmp/gtest-build

WORKDIR /app

COPY . ./calculator/

WORKDIR /app/calculator

CMD ["make"]
