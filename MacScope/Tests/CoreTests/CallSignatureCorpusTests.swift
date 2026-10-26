import XCTest
@testable import MacScope

final class CallSignatureCorpusTests: XCTestCase {
    func testNoDuplicateCanonicalNames() {
        let names = CallSignatureCorpus.all.map(\.canonicalName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.allSatisfy { !$0.hasPrefix("_") })
        XCTAssertEqual(names, Self.expectedCanonicalOrder, "Corpus order must remain deterministic")
    }

    func testCorpusDoesNotShadowSeeds() {
        let corpusNames = Set(CallSignatureCorpus.all.map(\.canonicalName))
        let seedNames = Set(CallSignatureCatalog.seeds.map(\.canonicalName))
        XCTAssertTrue(corpusNames.isDisjoint(with: seedNames))
    }

    func testNoRegisterFileOverflow() {
        for spec in CallSignatureCorpus.all {
            var integerCount = 0
            var floatCount = 0
            for parameter in spec.parameters {
                switch CallSignatureCatalog.typeClass(parameter.type) {
                case .integer:
                    integerCount += 1
                case .float:
                    floatCount += 1
                }
            }
            XCTAssertLessThanOrEqual(integerCount, 8, "\(spec.canonicalName) overflows integer arguments")
            XCTAssertLessThanOrEqual(floatCount, 8, "\(spec.canonicalName) overflows floating arguments")
        }
    }

    func testBareScalarParameterWidthsUseSDKRegisterClasses() {
        let expectedWidthByType: [String: Int] = [
            "clockid_t": 32,
            "dev_t": 32,
            "gid_t": 32,
            "int": 32,
            "long": 64,
            "long int": 64,
            "long long": 64,
            "mode_t": 16,
            "off_t": 64,
            "pthread_key_t": 64,
            "pthread_t": 64,
            "sae_associd_t": 32,
            "sae_connid_t": 32,
            "size_t": 64,
            "socklen_t": 32,
            "time_t": 64,
            "uid_t": 32,
            "uint32_t": 32,
            "unsigned int": 32,
            "va_list": 64,
            "wchar_t": 32,
        ]

        let bareScalarTypes = Set(
            CallSignatureCorpus.all
                .flatMap(\.parameters)
                .map(\.type)
                .filter { !$0.contains("*") && CallSignatureCatalog.typeClass($0) != .float }
        )
        XCTAssertEqual(
            bareScalarTypes,
            Set(expectedWidthByType.keys),
            "Every bare scalar parameter spelling must have a pinned SDK width"
        )

        for (type, width) in expectedWidthByType {
            XCTAssertEqual(
                CallSignatureCatalog.integerWidth(type),
                width,
                "\(type) must retain its SDK-pinned scalar width"
            )
        }

        for spec in CallSignatureCorpus.all {
            let assigned = CallSignatureCatalog.assignRegisters(spec.parameters)
            for (parameter, assignment) in zip(spec.parameters, assigned) {
                guard let width = expectedWidthByType[parameter.type] else { continue }
                let expectedPrefix = width <= 32 ? "w" : "x"
                XCTAssertTrue(
                    assignment.register.hasPrefix(expectedPrefix),
                    "\(spec.canonicalName).\(parameter.name) (\(parameter.type), \(width)-bit) was assigned \(assignment.register)"
                )
            }
        }
    }

    func testEveryCorpusReturnUsesABIRegisterAndFlowsThroughRet() {
        let expectedRegisterByType: [String: String] = [
            "DIR *": "x0",
            "FILE *": "x0",
            "char *": "x0",
            "clock_t": "x0",
            "const char *": "x0",
            "double": "d0",
            "float": "s0",
            "gid_t": "w0",
            "int": "w0",
            "long": "x0",
            "long double": "d0",
            "long int": "x0",
            "long long": "x0",
            "long long int": "x0",
            "mode_t": "w0",
            "off_t": "x0",
            "pid_t": "w0",
            "pthread_t": "x0",
            "size_t": "x0",
            "ssize_t": "x0",
            "struct dirent *": "x0",
            "struct tm *": "x0",
            "time_t": "x0",
            "uid_t": "w0",
            "uint32_t": "w0",
            "uint64_t": "x0",
            "unsigned int": "w0",
            "unsigned long": "x0",
            "unsigned long long": "x0",
            "void": "",
            "void *": "x0",
        ]

        XCTAssertEqual(
            Set(CallSignatureCorpus.all.map(\.returnType)),
            Set(expectedRegisterByType.keys),
            "Every corpus return spelling must have an explicit ABI result register"
        )

        let expectedIntegerWidthByReturnType: [String: Int] = [
            "clock_t": 64,
            "gid_t": 32,
            "int": 32,
            "long": 64,
            "long int": 64,
            "long long": 64,
            "long long int": 64,
            "mode_t": 16,
            "off_t": 64,
            "pid_t": 32,
            "pthread_t": 64,
            "size_t": 64,
            "ssize_t": 64,
            "time_t": 64,
            "uid_t": 32,
            "uint32_t": 32,
            "uint64_t": 64,
            "unsigned int": 32,
            "unsigned long": 64,
            "unsigned long long": 64,
        ]
        for (type, width) in expectedIntegerWidthByReturnType {
            XCTAssertEqual(CallSignatureCatalog.integerWidth(type), width,
                           "\(type) must retain its SDK-pinned return width")
        }

        for spec in CallSignatureCorpus.all {
            let rows = [
                InstructionRow(address: 0x1000, bytes: "", mnemonic: "bl", operands: "_\(spec.canonicalName)", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ]
            let fn = MacIRBuilder().buildFunction(name: "forward_\(spec.canonicalName)", instructions: rows)
            let result = fn.instructions.compactMap { instruction -> MacIRValue?? in
                guard case let .call(frame, result) = instruction.operation,
                      frame.target == "_\(spec.canonicalName)" else { return nil }
                return .some(result)
            }.first ?? nil
            let expectedRegister = expectedRegisterByType[spec.returnType]!

            if expectedRegister.isEmpty {
                XCTAssertNil(result, "\(spec.canonicalName) has a void return")
                XCTAssertNil(fn.returnValue, "\(spec.canonicalName) has a void return")
            } else {
                guard case let .register(name, _) = result else {
                    XCTFail("\(spec.canonicalName) must return through \(expectedRegister), got \(String(describing: result))")
                    continue
                }
                XCTAssertEqual(name, expectedRegister, "\(spec.canonicalName) (\(spec.returnType))")
                XCTAssertEqual(fn.returnValue, .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker), "\(spec.canonicalName) has no wrapper return evidence")
            }
            XCTAssertEqual(fn.returnType, expectedRegister.isEmpty ? "void" : "int64_t", "\(spec.canonicalName) wrapper return type")
        }
    }

    func testEveryEntryMatchesItsHeaderPrototype() {
        let specs = CallSignatureCorpus.all
        XCTAssertTrue((300...500).contains(specs.count), "Unexpected corpus size: \(specs.count)")

        let corpusNames = Set(specs.map(\.canonicalName))
        XCTAssertEqual(Set(Self.expectedPrototypes.keys), corpusNames,
                       "The SDK prototype oracle must cover the corpus exactly")

        for spec in specs {
            guard let expected = Self.expectedPrototypes[spec.canonicalName] else {
                XCTFail("Missing SDK prototype for \(spec.canonicalName)")
                continue
            }
            XCTAssertEqual(
                Self.normalize(Self.prototype(for: spec)),
                Self.normalize(expected),
                "Prototype mismatch for \(spec.canonicalName)"
            )
        }
    }

    private static func prototype(for spec: CallSignatureSpec) -> String {
        var parameters = spec.parameters.map { "\($0.type) \($0.name)" }
        if parameters.isEmpty {
            parameters = ["void"]
        }
        if spec.isVariadic {
            parameters.append("...")
        }
        return "\(spec.returnType) \(spec.canonicalName)(\(parameters.joined(separator: ", ")))"
    }

    private static func normalize(_ prototype: String) -> String {
        guard let open = prototype.firstIndex(of: "("),
              let close = prototype.lastIndex(of: ")"),
              open < close else {
            return prototype.filter { !$0.isWhitespace }
        }

        let prefix = prototype[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixTokens = prefix.split(whereSeparator: \.isWhitespace)
        guard let functionName = prefixTokens.last else {
            return prototype.filter { !$0.isWhitespace }
        }
        let returnType = prefixTokens.dropLast().joined(separator: " ")

        let parameterText = String(prototype[prototype.index(after: open)..<close])
        let parameterTypes = splitTopLevelParameters(parameterText).map { rawParameter in
            var parameter = rawParameter.trimmingCharacters(in: .whitespacesAndNewlines)
            parameter = parameter.replacingOccurrences(
                of: #"\(\s*\*\s*[A-Za-z_][A-Za-z0-9_]*\s*\)"#,
                with: "(*)",
                options: .regularExpression
            )
            if parameter != "void", parameter != "...", !parameter.contains("(*)") {
                parameter = parameter.replacingOccurrences(
                    of: #"\s+[A-Za-z_][A-Za-z0-9_]*\s*$"#,
                    with: "",
                    options: .regularExpression
                )
            }
            return parameter.filter { !$0.isWhitespace }
        }

        return returnType.filter { !$0.isWhitespace }
            + " " + functionName
            + "(" + parameterTypes.joined(separator: ",") + ")"
    }

    private static func splitTopLevelParameters(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        var depth = 0

        for index in text.indices {
            switch text[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
            case "," where depth == 0:
                result.append(String(text[start..<index]))
                start = text.index(after: index)
            default:
                break
            }
        }
        result.append(String(text[start...]))
        return result
    }

    private static let expectedCanonicalOrder: [String] = [
        "ffs ffsl ffsll fls flsl flsll memccpy memchr memcmp memmem memset_pattern16 memset_pattern4 memset_pattern8 stpcpy stpncpy strcasecmp strcasestr strchrnul strcoll strcspn strerror strerror_r strlcat strlcpy strmode strncasecmp strndup strnlen strnstr strpbrk strrchr strsep strsignal strsignal_r strspn strstr strtok strtok_r strxfrm timingsafe_bcmp",
        "abort abs aligned_alloc arc4random arc4random_buf arc4random_stir arc4random_uniform atof atoi atol atoll drand48 exit getenv getprogname labs llabs mblen mbstowcs mbtowc mkstemp posix_memalign putenv quick_exit rand rand_r random reallocf realpath setenv setprogname srand srand48 sranddev srandom srandomdev strtod strtof strtol strtold strtoll strtonum strtoul strtoull system unsetenv valloc wcstombs wctomb",
        "clearerr ctermid ctermid_r dprintf fclose fdopen feof ferror fflush fgetc fgetln fgetpos fgets fileno flockfile fmemopen fopen fprintf fpurge fputc fread freopen fscanf fseek fseeko fsetpos ftell ftello ftrylockfile funlockfile getc getc_unlocked getchar getchar_unlocked getdelim getline open_memstream pclose perror popen putc putc_unlocked putchar putchar_unlocked remove rename rewind scanf setbuf setbuffer setlinebuf setvbuf sprintf sscanf tmpfile ungetc vasprintf vdprintf vfprintf vfscanf vprintf vscanf vsnprintf vsprintf vsscanf",
        "digittoint isalnum isalpha isascii isblank iscntrl isdigit isgraph ishexnumber isideogram islower isnumber isphonogram isprint ispunct isrune isspace isspecial isupper isxdigit toascii tolower toupper",
        "asctime asctime_r clock clock_getres clock_gettime clock_gettime_nsec_np clock_settime ctime ctime_r difftime getdate gmtime gmtime_r localtime localtime_r mktime nanosleep posix2time strftime strptime time time2posix timegm timelocal timespec_get tzset tzsetwall",
        "access chdir chown close dup dup2 execv execve execvp fchdir fchown fork fsync ftruncate getcwd getegid geteuid getgid getgroups gethostname getpid getppid getuid isatty link lseek pipe pread pwrite read readlink rmdir sleep symlink unlink write",
        "creat fcntl flock open openat",
        "chmod fchmod fchmodat fstat fstatat futimens lstat mkdir mkdirat mkfifo mkfifoat mknod mknodat stat umask utimensat",
        "closedir dirfd fdopendir opendir readdir rewinddir seekdir telldir",
        "pthread_attr_destroy pthread_attr_getdetachstate pthread_attr_getguardsize pthread_attr_getstacksize pthread_attr_init pthread_attr_setdetachstate pthread_attr_setguardsize pthread_attr_setstack pthread_attr_setstacksize pthread_cancel pthread_cond_broadcast pthread_cond_destroy pthread_cond_init pthread_cond_signal pthread_cond_timedwait pthread_cond_wait pthread_condattr_destroy pthread_condattr_getpshared pthread_condattr_init pthread_condattr_setpshared pthread_detach pthread_equal pthread_exit pthread_getname_np pthread_getschedparam pthread_getspecific pthread_join pthread_key_delete pthread_main_np pthread_mutex_destroy pthread_mutex_init pthread_mutex_lock pthread_mutex_trylock pthread_mutex_unlock pthread_mutexattr_destroy pthread_mutexattr_getpshared pthread_mutexattr_gettype pthread_mutexattr_init pthread_mutexattr_setpshared pthread_mutexattr_settype pthread_rwlock_destroy pthread_rwlock_init pthread_rwlock_rdlock pthread_rwlock_tryrdlock pthread_rwlock_trywrlock pthread_rwlock_unlock pthread_rwlock_wrlock pthread_self pthread_setcancelstate pthread_setcanceltype pthread_setconcurrency pthread_setname_np pthread_setschedparam pthread_setspecific pthread_sigmask pthread_testcancel pthread_threadid_np",
        "accept bind connect connectx disconnectx getpeername getsockname getsockopt listen recv recvfrom recvmsg send sendfile sendmsg sendto setsockopt shutdown sockatmark socket socketpair",
        "acos acosf acosh acoshf asin asinf asinh asinhf atan atan2 atan2f atanf atanh atanhf cbrt cbrtf ceil ceilf copysign copysignf cos cosf cosh coshf erf erfc erfcf erff exp exp2 exp2f expf expm1 expm1f fabs fabsf fdim fdimf floor floorf fma fmaf fmax fmaxf fmin fminf fmod fmodf frexp frexpf hypot hypotf ilogb ilogbf j0 j1 jn ldexp ldexpf lgamma lgamma_r lgammaf lgammaf_r llrint llrintf llround llroundf log log10 log10f log1p log1pf log2 log2f logb logbf logf lrint lrintf lround lroundf modf modff nan nanf nearbyint nearbyintf nextafter nextafterf pow powf remainder remainderf remquo remquof rint rintf round roundf scalbln scalblnf scalbn scalbnf sin sinf sinh sinhf sqrt sqrtf tan tanf tanh tanhf tgamma tgammaf trunc truncf y0 y1 yn",
    ].flatMap { $0.split(separator: " ").map(String.init) }

    // Transcribed from the active macOS SDK headers named by each group.
    private static let expectedPrototypes: [String: String] = [

        // <string.h> and <strings.h>
        "ffs": "int ffs(int value)",
        "ffsl": "int ffsl(long value)",
        "ffsll": "int ffsll(long long value)",
        "fls": "int fls(int value)",
        "flsl": "int flsl(long value)",
        "flsll": "int flsll(long long value)",
        "memccpy": "void * memccpy(void * dst, const void * src, int c, size_t n)",
        "memchr": "void * memchr(const void * s, int c, size_t n)",
        "memcmp": "int memcmp(const void * s1, const void * s2, size_t n)",
        "memmem": "void * memmem(const void * big, size_t big_len, const void * little, size_t little_len)",
        "memset_pattern16": "void memset_pattern16(void * b, const void * pattern16, size_t len)",
        "memset_pattern4": "void memset_pattern4(void * b, const void * pattern4, size_t len)",
        "memset_pattern8": "void memset_pattern8(void * b, const void * pattern8, size_t len)",
        "stpcpy": "char * stpcpy(char * dst, const char * src)",
        "stpncpy": "char * stpncpy(char * dst, const char * src, size_t len)",
        "strcasecmp": "int strcasecmp(const char * s1, const char * s2)",
        "strcasestr": "char * strcasestr(const char * haystack, const char * needle)",
        "strchrnul": "char * strchrnul(const char * s, int c)",
        "strcoll": "int strcoll(const char * s1, const char * s2)",
        "strcspn": "size_t strcspn(const char * s, const char * charset)",
        "strerror": "char * strerror(int errnum)",
        "strerror_r": "int strerror_r(int errnum, char * strerrbuf, size_t buflen)",
        "strlcat": "size_t strlcat(char * dst, const char * src, size_t dstsize)",
        "strlcpy": "size_t strlcpy(char * dst, const char * src, size_t dstsize)",
        "strmode": "void strmode(int mode, char * bp)",
        "strncasecmp": "int strncasecmp(const char * s1, const char * s2, size_t n)",
        "strndup": "char * strndup(const char * s1, size_t n)",
        "strnlen": "size_t strnlen(const char * s, size_t maxlen)",
        "strnstr": "char * strnstr(const char * haystack, const char * needle, size_t len)",
        "strpbrk": "char * strpbrk(const char * s, const char * charset)",
        "strrchr": "char * strrchr(const char * s, int c)",
        "strsep": "char * strsep(char ** stringp, const char * delim)",
        "strsignal": "char * strsignal(int sig)",
        "strsignal_r": "int strsignal_r(int sig, char * strsignalbuf, size_t buflen)",
        "strspn": "size_t strspn(const char * s, const char * charset)",
        "strstr": "char * strstr(const char * haystack, const char * needle)",
        "strtok": "char * strtok(char * str, const char * sep)",
        "strtok_r": "char * strtok_r(char * str, const char * sep, char ** lasts)",
        "strxfrm": "size_t strxfrm(char * s1, const char * s2, size_t n)",
        "timingsafe_bcmp": "int timingsafe_bcmp(const void * b1, const void * b2, size_t len)",

        // <stdlib.h>
        "abort": "void abort(void)",
        "abs": "int abs(int value)",
        "aligned_alloc": "void * aligned_alloc(size_t alignment, size_t size)",
        "arc4random": "uint32_t arc4random(void)",
        "arc4random_buf": "void arc4random_buf(void * buffer, size_t byteCount)",
        "arc4random_stir": "void arc4random_stir(void)",
        "arc4random_uniform": "uint32_t arc4random_uniform(uint32_t upperBound)",
        "atof": "double atof(const char * string)",
        "atoi": "int atoi(const char * string)",
        "atol": "long atol(const char * string)",
        "atoll": "long long atoll(const char * string)",
        "drand48": "double drand48(void)",
        "exit": "void exit(int status)",
        "getenv": "char * getenv(const char * name)",
        "getprogname": "const char * getprogname(void)",
        "labs": "long labs(long value)",
        "llabs": "long long llabs(long long value)",
        "mblen": "int mblen(const char * string, size_t byteCount)",
        "mbstowcs": "size_t mbstowcs(wchar_t * restrict destination, const char * restrict source, size_t count)",
        "mbtowc": "int mbtowc(wchar_t * restrict wideCharacter, const char * restrict source, size_t byteCount)",
        "mkstemp": "int mkstemp(char * template)",
        "posix_memalign": "int posix_memalign(void ** memoryPointer, size_t alignment, size_t size)",
        "putenv": "int putenv(char * string)",
        "quick_exit": "void quick_exit(int status)",
        "rand": "int rand(void)",
        "rand_r": "int rand_r(unsigned int * seed)",
        "random": "long random(void)",
        "reallocf": "void * reallocf(void * pointer, size_t size)",
        "realpath": "char * realpath(const char * restrict path, char * restrict resolvedPath)",
        "setenv": "int setenv(const char * name, const char * value, int overwrite)",
        "setprogname": "void setprogname(const char * programName)",
        "srand": "void srand(unsigned int seed)",
        "srand48": "void srand48(long seed)",
        "sranddev": "void sranddev(void)",
        "srandom": "void srandom(unsigned int seed)",
        "srandomdev": "void srandomdev(void)",
        "strtod": "double strtod(const char * string, char ** endPointer)",
        "strtof": "float strtof(const char * string, char ** endPointer)",
        "strtol": "long strtol(const char * string, char ** endPointer, int base)",
        "strtold": "long double strtold(const char * string, char ** endPointer)",
        "strtoll": "long long strtoll(const char * string, char ** endPointer, int base)",
        "strtonum": "long long strtonum(const char * string, long long minimum, long long maximum, const char ** errorString)",
        "strtoul": "unsigned long strtoul(const char * string, char ** endPointer, int base)",
        "strtoull": "unsigned long long strtoull(const char * string, char ** endPointer, int base)",
        "system": "int system(const char * command)",
        "unsetenv": "int unsetenv(const char * name)",
        "valloc": "void * valloc(size_t size)",
        "wcstombs": "size_t wcstombs(char * restrict destination, const wchar_t * restrict source, size_t count)",
        "wctomb": "int wctomb(char * destination, wchar_t wideCharacter)",

        // <stdio.h>
        "clearerr": "void clearerr(FILE * stream)",
        "ctermid": "char * ctermid(char * buffer)",
        "ctermid_r": "char * ctermid_r(char * buffer)",
        "dprintf": "int dprintf(int fileDescriptor, const char * restrict format, ...)",
        "fclose": "int fclose(FILE * stream)",
        "fdopen": "FILE * fdopen(int fileDescriptor, const char * mode)",
        "feof": "int feof(FILE * stream)",
        "ferror": "int ferror(FILE * stream)",
        "fflush": "int fflush(FILE * stream)",
        "fgetc": "int fgetc(FILE * stream)",
        "fgetln": "char * fgetln(FILE * stream, size_t * length)",
        "fgetpos": "int fgetpos(FILE * restrict stream, fpos_t * position)",
        "fgets": "char * fgets(char * restrict buffer, int size, FILE * stream)",
        "fileno": "int fileno(FILE * stream)",
        "flockfile": "void flockfile(FILE * stream)",
        "fmemopen": "FILE * fmemopen(void * restrict buffer, size_t size, const char * restrict mode)",
        "fopen": "FILE * fopen(const char * restrict path, const char * restrict mode)",
        "fprintf": "int fprintf(FILE * restrict stream, const char * restrict format, ...)",
        "fpurge": "int fpurge(FILE * stream)",
        "fputc": "int fputc(int character, FILE * stream)",
        "fread": "size_t fread(void * restrict pointer, size_t size, size_t count, FILE * restrict stream)",
        "freopen": "FILE * freopen(const char * restrict path, const char * restrict mode, FILE * restrict stream)",
        "fscanf": "int fscanf(FILE * restrict stream, const char * restrict format, ...)",
        "fseek": "int fseek(FILE * stream, long offset, int whence)",
        "fseeko": "int fseeko(FILE * stream, off_t offset, int whence)",
        "fsetpos": "int fsetpos(FILE * stream, const fpos_t * position)",
        "ftell": "long ftell(FILE * stream)",
        "ftello": "off_t ftello(FILE * stream)",
        "ftrylockfile": "int ftrylockfile(FILE * stream)",
        "funlockfile": "void funlockfile(FILE * stream)",
        "getc": "int getc(FILE * stream)",
        "getc_unlocked": "int getc_unlocked(FILE * stream)",
        "getchar": "int getchar(void)",
        "getchar_unlocked": "int getchar_unlocked(void)",
        "getdelim": "ssize_t getdelim(char ** restrict linePointer, size_t * restrict capacity, int delimiter, FILE * restrict stream)",
        "getline": "ssize_t getline(char ** restrict linePointer, size_t * restrict capacity, FILE * restrict stream)",
        "open_memstream": "FILE * open_memstream(char ** bufferPointer, size_t * sizePointer)",
        "pclose": "int pclose(FILE * stream)",
        "perror": "void perror(const char * message)",
        "popen": "FILE * popen(const char * command, const char * mode)",
        "putc": "int putc(int character, FILE * stream)",
        "putc_unlocked": "int putc_unlocked(int character, FILE * stream)",
        "putchar": "int putchar(int character)",
        "putchar_unlocked": "int putchar_unlocked(int character)",
        "remove": "int remove(const char * path)",
        "rename": "int rename(const char * oldPath, const char * newPath)",
        "rewind": "void rewind(FILE * stream)",
        "scanf": "int scanf(const char * restrict format, ...)",
        "setbuf": "void setbuf(FILE * restrict stream, char * restrict buffer)",
        "setbuffer": "void setbuffer(FILE * stream, char * buffer, int size)",
        "setlinebuf": "int setlinebuf(FILE * stream)",
        "setvbuf": "int setvbuf(FILE * restrict stream, char * restrict buffer, int mode, size_t size)",
        "sprintf": "int sprintf(char * restrict buffer, const char * restrict format, ...)",
        "sscanf": "int sscanf(const char * restrict string, const char * restrict format, ...)",
        "tmpfile": "FILE * tmpfile(void)",
        "ungetc": "int ungetc(int character, FILE * stream)",
        "vasprintf": "int vasprintf(char ** restrict result, const char * restrict format, va_list arguments)",
        "vdprintf": "int vdprintf(int fileDescriptor, const char * restrict format, va_list arguments)",
        "vfprintf": "int vfprintf(FILE * restrict stream, const char * restrict format, va_list arguments)",
        "vfscanf": "int vfscanf(FILE * restrict stream, const char * restrict format, va_list arguments)",
        "vprintf": "int vprintf(const char * restrict format, va_list arguments)",
        "vscanf": "int vscanf(const char * restrict format, va_list arguments)",
        "vsnprintf": "int vsnprintf(char * restrict buffer, size_t size, const char * restrict format, va_list arguments)",
        "vsprintf": "int vsprintf(char * restrict buffer, const char * restrict format, va_list arguments)",
        "vsscanf": "int vsscanf(const char * restrict string, const char * restrict format, va_list arguments)",

        // <ctype.h>
        "digittoint": "int digittoint(int c)",
        "isalnum": "int isalnum(int c)",
        "isalpha": "int isalpha(int c)",
        "isascii": "int isascii(int c)",
        "isblank": "int isblank(int c)",
        "iscntrl": "int iscntrl(int c)",
        "isdigit": "int isdigit(int c)",
        "isgraph": "int isgraph(int c)",
        "ishexnumber": "int ishexnumber(int c)",
        "isideogram": "int isideogram(int c)",
        "islower": "int islower(int c)",
        "isnumber": "int isnumber(int c)",
        "isphonogram": "int isphonogram(int c)",
        "isprint": "int isprint(int c)",
        "ispunct": "int ispunct(int c)",
        "isrune": "int isrune(int c)",
        "isspace": "int isspace(int c)",
        "isspecial": "int isspecial(int c)",
        "isupper": "int isupper(int c)",
        "isxdigit": "int isxdigit(int c)",
        "toascii": "int toascii(int c)",
        "tolower": "int tolower(int c)",
        "toupper": "int toupper(int c)",

        // <time.h>
        "asctime": "char * asctime(const struct tm * timeptr)",
        "asctime_r": "char * asctime_r(const struct tm * restrict timeptr, char * restrict buf)",
        "clock": "clock_t clock(void)",
        "clock_getres": "int clock_getres(clockid_t clock_id, struct timespec * tp)",
        "clock_gettime": "int clock_gettime(clockid_t clock_id, struct timespec * tp)",
        "clock_gettime_nsec_np": "uint64_t clock_gettime_nsec_np(clockid_t clock_id)",
        "clock_settime": "int clock_settime(clockid_t clock_id, const struct timespec * tp)",
        "ctime": "char * ctime(const time_t * clock)",
        "ctime_r": "char * ctime_r(const time_t * clock, char * buf)",
        "difftime": "double difftime(time_t time1, time_t time0)",
        "getdate": "struct tm * getdate(const char * string)",
        "gmtime": "struct tm * gmtime(const time_t * clock)",
        "gmtime_r": "struct tm * gmtime_r(const time_t * clock, struct tm * result)",
        "localtime": "struct tm * localtime(const time_t * clock)",
        "localtime_r": "struct tm * localtime_r(const time_t * clock, struct tm * result)",
        "mktime": "time_t mktime(struct tm * timeptr)",
        "nanosleep": "int nanosleep(const struct timespec * rqtp, struct timespec * rmtp)",
        "posix2time": "time_t posix2time(time_t t)",
        "strftime": "size_t strftime(char * restrict s, size_t maxsize, const char * restrict format, const struct tm * restrict timeptr)",
        "strptime": "char * strptime(const char * restrict buf, const char * restrict format, struct tm * restrict timeptr)",
        "time": "time_t time(time_t * tloc)",
        "time2posix": "time_t time2posix(time_t t)",
        "timegm": "time_t timegm(struct tm * timeptr)",
        "timelocal": "time_t timelocal(struct tm * timeptr)",
        "timespec_get": "int timespec_get(struct timespec * ts, int base)",
        "tzset": "void tzset(void)",
        "tzsetwall": "void tzsetwall(void)",

        // <unistd.h>
        "access": "int access(const char * path, int mode)",
        "chdir": "int chdir(const char * path)",
        "chown": "int chown(const char * path, uid_t owner, gid_t group)",
        "close": "int close(int fildes)",
        "dup": "int dup(int fildes)",
        "dup2": "int dup2(int fildes, int fildes2)",
        "execv": "int execv(const char * path, char * const * argv)",
        "execve": "int execve(const char * file, char * const * argv, char * const * envp)",
        "execvp": "int execvp(const char * file, char * const * argv)",
        "fchdir": "int fchdir(int fildes)",
        "fchown": "int fchown(int fildes, uid_t owner, gid_t group)",
        "fork": "pid_t fork(void)",
        "fsync": "int fsync(int fildes)",
        "ftruncate": "int ftruncate(int fildes, off_t length)",
        "getcwd": "char * getcwd(char * buf, size_t size)",
        "getegid": "gid_t getegid(void)",
        "geteuid": "uid_t geteuid(void)",
        "getgid": "gid_t getgid(void)",
        "getgroups": "int getgroups(int gidsetsize, gid_t * grouplist)",
        "gethostname": "int gethostname(char * name, size_t namelen)",
        "getpid": "pid_t getpid(void)",
        "getppid": "pid_t getppid(void)",
        "getuid": "uid_t getuid(void)",
        "isatty": "int isatty(int fd)",
        "link": "int link(const char * path1, const char * path2)",
        "lseek": "off_t lseek(int fildes, off_t offset, int whence)",
        "pipe": "int pipe(int * fildes)",
        "pread": "ssize_t pread(int fildes, void * buf, size_t nbyte, off_t offset)",
        "pwrite": "ssize_t pwrite(int fildes, const void * buf, size_t nbyte, off_t offset)",
        "read": "ssize_t read(int fildes, void * buf, size_t nbyte)",
        "readlink": "ssize_t readlink(const char * restrict path, char * restrict buf, size_t bufsize)",
        "rmdir": "int rmdir(const char * path)",
        "sleep": "unsigned int sleep(unsigned int seconds)",
        "symlink": "int symlink(const char * path1, const char * path2)",
        "unlink": "int unlink(const char * path)",
        "write": "ssize_t write(int fildes, const void * buf, size_t nbyte)",

        // <fcntl.h>
        "creat": "int creat(const char * path, mode_t mode)",
        "fcntl": "int fcntl(int fildes, int cmd, ...)",
        "flock": "int flock(int fd, int operation)",
        "open": "int open(const char * path, int oflag, ...)",
        "openat": "int openat(int fd, const char * path, int oflag, ...)",

        // <sys/stat.h>
        "chmod": "int chmod(const char * path, mode_t mode)",
        "fchmod": "int fchmod(int fildes, mode_t mode)",
        "fchmodat": "int fchmodat(int fd, const char * path, mode_t mode, int flag)",
        "fstat": "int fstat(int fildes, struct stat * buf)",
        "fstatat": "int fstatat(int fd, const char * path, struct stat * buf, int flag)",
        "futimens": "int futimens(int fd, const struct timespec * times)",
        "lstat": "int lstat(const char * path, struct stat * buf)",
        "mkdir": "int mkdir(const char * path, mode_t mode)",
        "mkdirat": "int mkdirat(int fd, const char * path, mode_t mode)",
        "mkfifo": "int mkfifo(const char * path, mode_t mode)",
        "mkfifoat": "int mkfifoat(int fd, const char * path, mode_t mode)",
        "mknod": "int mknod(const char * path, mode_t mode, dev_t dev)",
        "mknodat": "int mknodat(int fd, const char * path, mode_t mode, dev_t dev)",
        "stat": "int stat(const char * path, struct stat * buf)",
        "umask": "mode_t umask(mode_t cmask)",
        "utimensat": "int utimensat(int fd, const char * path, const struct timespec * times, int flag)",

        // <dirent.h>
        "closedir": "int closedir(DIR * dirp)",
        "dirfd": "int dirfd(DIR * dirp)",
        "fdopendir": "DIR * fdopendir(int fd)",
        "opendir": "DIR * opendir(const char * filename)",
        "readdir": "struct dirent * readdir(DIR * dirp)",
        "rewinddir": "void rewinddir(DIR * dirp)",
        "seekdir": "void seekdir(DIR * dirp, long loc)",
        "telldir": "long telldir(DIR * dirp)",

        // <pthread.h>
        "pthread_attr_destroy": "int pthread_attr_destroy(pthread_attr_t * attr)",
        "pthread_attr_getdetachstate": "int pthread_attr_getdetachstate(const pthread_attr_t * attr, int * detachstate)",
        "pthread_attr_getguardsize": "int pthread_attr_getguardsize(const pthread_attr_t * attr, size_t * guardsize)",
        "pthread_attr_getstacksize": "int pthread_attr_getstacksize(const pthread_attr_t * attr, size_t * stacksize)",
        "pthread_attr_init": "int pthread_attr_init(pthread_attr_t * attr)",
        "pthread_attr_setdetachstate": "int pthread_attr_setdetachstate(pthread_attr_t * attr, int detachstate)",
        "pthread_attr_setguardsize": "int pthread_attr_setguardsize(pthread_attr_t * attr, size_t guardsize)",
        "pthread_attr_setstack": "int pthread_attr_setstack(pthread_attr_t * attr, void * stackaddr, size_t stacksize)",
        "pthread_attr_setstacksize": "int pthread_attr_setstacksize(pthread_attr_t * attr, size_t stacksize)",
        "pthread_cancel": "int pthread_cancel(pthread_t thread)",
        "pthread_cond_broadcast": "int pthread_cond_broadcast(pthread_cond_t * cond)",
        "pthread_cond_destroy": "int pthread_cond_destroy(pthread_cond_t * cond)",
        "pthread_cond_init": "int pthread_cond_init(pthread_cond_t * cond, const pthread_condattr_t * attr)",
        "pthread_cond_signal": "int pthread_cond_signal(pthread_cond_t * cond)",
        "pthread_cond_timedwait": "int pthread_cond_timedwait(pthread_cond_t * cond, pthread_mutex_t * mutex, const struct timespec * abstime)",
        "pthread_cond_wait": "int pthread_cond_wait(pthread_cond_t * cond, pthread_mutex_t * mutex)",
        "pthread_condattr_destroy": "int pthread_condattr_destroy(pthread_condattr_t * attr)",
        "pthread_condattr_getpshared": "int pthread_condattr_getpshared(const pthread_condattr_t * attr, int * pshared)",
        "pthread_condattr_init": "int pthread_condattr_init(pthread_condattr_t * attr)",
        "pthread_condattr_setpshared": "int pthread_condattr_setpshared(pthread_condattr_t * attr, int pshared)",
        "pthread_detach": "int pthread_detach(pthread_t thread)",
        "pthread_equal": "int pthread_equal(pthread_t t1, pthread_t t2)",
        "pthread_exit": "void pthread_exit(void * value_ptr)",
        "pthread_getname_np": "int pthread_getname_np(pthread_t thread, char * name, size_t len)",
        "pthread_getschedparam": "int pthread_getschedparam(pthread_t thread, int * policy, struct sched_param * param)",
        "pthread_getspecific": "void * pthread_getspecific(pthread_key_t key)",
        "pthread_join": "int pthread_join(pthread_t thread, void ** value_ptr)",
        "pthread_key_delete": "int pthread_key_delete(pthread_key_t key)",
        "pthread_main_np": "int pthread_main_np(void)",
        "pthread_mutex_destroy": "int pthread_mutex_destroy(pthread_mutex_t * mutex)",
        "pthread_mutex_init": "int pthread_mutex_init(pthread_mutex_t * mutex, const pthread_mutexattr_t * attr)",
        "pthread_mutex_lock": "int pthread_mutex_lock(pthread_mutex_t * mutex)",
        "pthread_mutex_trylock": "int pthread_mutex_trylock(pthread_mutex_t * mutex)",
        "pthread_mutex_unlock": "int pthread_mutex_unlock(pthread_mutex_t * mutex)",
        "pthread_mutexattr_destroy": "int pthread_mutexattr_destroy(pthread_mutexattr_t * attr)",
        "pthread_mutexattr_getpshared": "int pthread_mutexattr_getpshared(const pthread_mutexattr_t * attr, int * pshared)",
        "pthread_mutexattr_gettype": "int pthread_mutexattr_gettype(const pthread_mutexattr_t * attr, int * type)",
        "pthread_mutexattr_init": "int pthread_mutexattr_init(pthread_mutexattr_t * attr)",
        "pthread_mutexattr_setpshared": "int pthread_mutexattr_setpshared(pthread_mutexattr_t * attr, int pshared)",
        "pthread_mutexattr_settype": "int pthread_mutexattr_settype(pthread_mutexattr_t * attr, int type)",
        "pthread_rwlock_destroy": "int pthread_rwlock_destroy(pthread_rwlock_t * lock)",
        "pthread_rwlock_init": "int pthread_rwlock_init(pthread_rwlock_t * lock, const pthread_rwlockattr_t * attr)",
        "pthread_rwlock_rdlock": "int pthread_rwlock_rdlock(pthread_rwlock_t * lock)",
        "pthread_rwlock_tryrdlock": "int pthread_rwlock_tryrdlock(pthread_rwlock_t * lock)",
        "pthread_rwlock_trywrlock": "int pthread_rwlock_trywrlock(pthread_rwlock_t * lock)",
        "pthread_rwlock_unlock": "int pthread_rwlock_unlock(pthread_rwlock_t * lock)",
        "pthread_rwlock_wrlock": "int pthread_rwlock_wrlock(pthread_rwlock_t * lock)",
        "pthread_self": "pthread_t pthread_self(void)",
        "pthread_setcancelstate": "int pthread_setcancelstate(int state, int * oldstate)",
        "pthread_setcanceltype": "int pthread_setcanceltype(int type, int * oldtype)",
        "pthread_setconcurrency": "int pthread_setconcurrency(int new_level)",
        "pthread_setname_np": "int pthread_setname_np(const char * name)",
        "pthread_setschedparam": "int pthread_setschedparam(pthread_t thread, int policy, const struct sched_param * param)",
        "pthread_setspecific": "int pthread_setspecific(pthread_key_t key, const void * value)",
        "pthread_sigmask": "int pthread_sigmask(int how, const sigset_t * set, sigset_t * oldset)",
        "pthread_testcancel": "void pthread_testcancel(void)",
        "pthread_threadid_np": "int pthread_threadid_np(pthread_t thread, uint64_t * thread_id)",

        // <sys/socket.h>
        "accept": "int accept(int socket, struct sockaddr * address, socklen_t * address_len)",
        "bind": "int bind(int socket, const struct sockaddr * address, socklen_t address_len)",
        "connect": "int connect(int socket, const struct sockaddr * address, socklen_t address_len)",
        "connectx": "int connectx(int socket, const sa_endpoints_t * endpoints, sae_associd_t associd, unsigned int flags, const struct iovec * iov, unsigned int iovcnt, size_t * len, sae_connid_t * connid)",
        "disconnectx": "int disconnectx(int socket, sae_associd_t associd, sae_connid_t connid)",
        "getpeername": "int getpeername(int socket, struct sockaddr * address, socklen_t * address_len)",
        "getsockname": "int getsockname(int socket, struct sockaddr * address, socklen_t * address_len)",
        "getsockopt": "int getsockopt(int socket, int level, int option_name, void * option_value, socklen_t * option_len)",
        "listen": "int listen(int socket, int backlog)",
        "recv": "ssize_t recv(int socket, void * buffer, size_t length, int flags)",
        "recvfrom": "ssize_t recvfrom(int socket, void * buffer, size_t length, int flags, struct sockaddr * address, socklen_t * address_len)",
        "recvmsg": "ssize_t recvmsg(int socket, struct msghdr * message, int flags)",
        "send": "ssize_t send(int socket, const void * buffer, size_t length, int flags)",
        "sendfile": "int sendfile(int fd, int s, off_t offset, off_t * len, struct sf_hdtr * hdtr, int flags)",
        "sendmsg": "ssize_t sendmsg(int socket, const struct msghdr * message, int flags)",
        "sendto": "ssize_t sendto(int socket, const void * buffer, size_t length, int flags, const struct sockaddr * dest_addr, socklen_t dest_len)",
        "setsockopt": "int setsockopt(int socket, int level, int option_name, const void * option_value, socklen_t option_len)",
        "shutdown": "int shutdown(int socket, int how)",
        "sockatmark": "int sockatmark(int s)",
        "socket": "int socket(int domain, int type, int protocol)",
        "socketpair": "int socketpair(int domain, int type, int protocol, int * socket_vector)",

        // <math.h>
        "acos": "double acos(double x)",
        "acosf": "float acosf(float x)",
        "acosh": "double acosh(double x)",
        "acoshf": "float acoshf(float x)",
        "asin": "double asin(double x)",
        "asinf": "float asinf(float x)",
        "asinh": "double asinh(double x)",
        "asinhf": "float asinhf(float x)",
        "atan": "double atan(double x)",
        "atan2": "double atan2(double y, double x)",
        "atan2f": "float atan2f(float y, float x)",
        "atanf": "float atanf(float x)",
        "atanh": "double atanh(double x)",
        "atanhf": "float atanhf(float x)",
        "cbrt": "double cbrt(double x)",
        "cbrtf": "float cbrtf(float x)",
        "ceil": "double ceil(double x)",
        "ceilf": "float ceilf(float x)",
        "copysign": "double copysign(double x, double y)",
        "copysignf": "float copysignf(float x, float y)",
        "cos": "double cos(double x)",
        "cosf": "float cosf(float x)",
        "cosh": "double cosh(double x)",
        "coshf": "float coshf(float x)",
        "erf": "double erf(double x)",
        "erfc": "double erfc(double x)",
        "erfcf": "float erfcf(float x)",
        "erff": "float erff(float x)",
        "exp": "double exp(double x)",
        "exp2": "double exp2(double x)",
        "exp2f": "float exp2f(float x)",
        "expf": "float expf(float x)",
        "expm1": "double expm1(double x)",
        "expm1f": "float expm1f(float x)",
        "fabs": "double fabs(double x)",
        "fabsf": "float fabsf(float x)",
        "fdim": "double fdim(double x, double y)",
        "fdimf": "float fdimf(float x, float y)",
        "floor": "double floor(double x)",
        "floorf": "float floorf(float x)",
        "fma": "double fma(double x, double y, double z)",
        "fmaf": "float fmaf(float x, float y, float z)",
        "fmax": "double fmax(double x, double y)",
        "fmaxf": "float fmaxf(float x, float y)",
        "fmin": "double fmin(double x, double y)",
        "fminf": "float fminf(float x, float y)",
        "fmod": "double fmod(double x, double y)",
        "fmodf": "float fmodf(float x, float y)",
        "frexp": "double frexp(double value, int * exp)",
        "frexpf": "float frexpf(float value, int * exp)",
        "hypot": "double hypot(double x, double y)",
        "hypotf": "float hypotf(float x, float y)",
        "ilogb": "int ilogb(double x)",
        "ilogbf": "int ilogbf(float x)",
        "j0": "double j0(double x)",
        "j1": "double j1(double x)",
        "jn": "double jn(int n, double x)",
        "ldexp": "double ldexp(double x, int n)",
        "ldexpf": "float ldexpf(float x, int n)",
        "lgamma": "double lgamma(double x)",
        "lgamma_r": "double lgamma_r(double x, int * psigngam)",
        "lgammaf": "float lgammaf(float x)",
        "lgammaf_r": "float lgammaf_r(float x, int * psigngam)",
        "llrint": "long long int llrint(double x)",
        "llrintf": "long long int llrintf(float x)",
        "llround": "long long int llround(double x)",
        "llroundf": "long long int llroundf(float x)",
        "log": "double log(double x)",
        "log10": "double log10(double x)",
        "log10f": "float log10f(float x)",
        "log1p": "double log1p(double x)",
        "log1pf": "float log1pf(float x)",
        "log2": "double log2(double x)",
        "log2f": "float log2f(float x)",
        "logb": "double logb(double x)",
        "logbf": "float logbf(float x)",
        "logf": "float logf(float x)",
        "lrint": "long int lrint(double x)",
        "lrintf": "long int lrintf(float x)",
        "lround": "long int lround(double x)",
        "lroundf": "long int lroundf(float x)",
        "modf": "double modf(double value, double * iptr)",
        "modff": "float modff(float value, float * iptr)",
        "nan": "double nan(const char * tagp)",
        "nanf": "float nanf(const char * tagp)",
        "nearbyint": "double nearbyint(double x)",
        "nearbyintf": "float nearbyintf(float x)",
        "nextafter": "double nextafter(double x, double y)",
        "nextafterf": "float nextafterf(float x, float y)",
        "pow": "double pow(double x, double y)",
        "powf": "float powf(float x, float y)",
        "remainder": "double remainder(double x, double y)",
        "remainderf": "float remainderf(float x, float y)",
        "remquo": "double remquo(double x, double y, int * quo)",
        "remquof": "float remquof(float x, float y, int * quo)",
        "rint": "double rint(double x)",
        "rintf": "float rintf(float x)",
        "round": "double round(double x)",
        "roundf": "float roundf(float x)",
        "scalbln": "double scalbln(double x, long int n)",
        "scalblnf": "float scalblnf(float x, long int n)",
        "scalbn": "double scalbn(double x, int n)",
        "scalbnf": "float scalbnf(float x, int n)",
        "sin": "double sin(double x)",
        "sinf": "float sinf(float x)",
        "sinh": "double sinh(double x)",
        "sinhf": "float sinhf(float x)",
        "sqrt": "double sqrt(double x)",
        "sqrtf": "float sqrtf(float x)",
        "tan": "double tan(double x)",
        "tanf": "float tanf(float x)",
        "tanh": "double tanh(double x)",
        "tanhf": "float tanhf(float x)",
        "tgamma": "double tgamma(double x)",
        "tgammaf": "float tgammaf(float x)",
        "trunc": "double trunc(double x)",
        "truncf": "float truncf(float x)",
        "y0": "double y0(double x)",
        "y1": "double y1(double x)",
        "yn": "double yn(int n, double x)",
    ]
}
