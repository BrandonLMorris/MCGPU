#######################################
# MCGPU Makefile
# Version 2.0
# Authors: Tavis Maclellan
# 
# This Makefile depends on GNU make.
#
########################
# Makefile Target List #
########################
#
# make [all]   : Comiles all source files and builds the metrosim application
#				 in release mode.
# make release : Compiles all source files and builds a release version
#			     of the metrosim application.
# make debug   : Compiles all source files and builds a debug version of
#			     the metrosim application. Debug output is now enabled.
# make clean   : Deletes the object and bin directories from the project
#			     folder.
#
#############################
# Project Structure Details #
#############################
#
# SourceDir : Contains the source code and header files
# TestDir   : Contains the testing code and testing input files
# ObjDir    : This folder is created by the Makefile and will be poulated
#             with compiled object files and binaries
# BinDir    : This folder is created by the Makefile and will hold the
#             generated program executable files
#
SourceDir := src
TestDir := test
ObjDir := obj
BinDir := bin

# The path to the output directory where the built executable will be stored.
# This is necessary because the debug and release builds will be stored
# in different folders. This will be set when the build type is determined.
AppDir :=

# Defines the modules that exist in the source directory that should be
# included by the compiler. All files within these directories that are
# valid file types for the Makefile to handle will automatically be
# compiled into object files in the object directory. Make sure to add
# any new modules to this list, or else they will not be compiled.
Modules := Applications 				\
		   Metropolis                   \
		   Metropolis/Utilities 		\
		   Metropolis/SerialSim		    \
		   Metropolis/ParallelSim

##############################
# Compiler Specific Settings #
##############################

# Defines the compilers used to compile and link the source files.
# CC will be used to compile C++ files, and NVCC will be used to
# compile CUDA files.
CC := g++
NVCC := nvcc

# Defines the types of files that the Makefile knows how to compile
# and link. Specify the filetype by using a modulus (percent sign),
# followed by a dot and the file extension (e.g. %.java, %.txt).
FileTypes := %.cpp %.cu

# Relative search paths for Include Files
IncPaths := $(SourceDir) $(TestDir) .

# Compiler specific flags for the C++ compiler when generating .o files
# and when generating .d files for dependency information
CxxFlags := -c

# Compiler specific flags for the CUDA compiler when generating .o files
# and when generating .d files for dependency information
CuFlags := -c -arch=sm_35 -rdc=true

# Linker specific flags for the C++ compiler
LCxxFlags :=

# Linker specific flags for the CUDA compiler
LCuFlags := -arch=sm_35 -rdc=true

# The debug compiler flags that add symbol and profiling hooks to the
# executable for C++ code
CxxDebugFlags := -g -pg

# The debug compiler flags that add symbol and profiling hooks to the
# executable for both host and device code in CUDA files.
CuDebugFlags := -g -G -pg

# The release build compiler flags that add optimization flags and remove
# all symbol and relocation table information from the executable.
CxxReleaseFlags := -O2 -s

# The release build comiler flags that add optimization flags to the
# executable.
CuReleaseFlags := -O2

########################
# Program Output Names #
########################

# The name of the program generated by the makefile
AppName := metrosim

# The name of the unit testing program generated by the makefile
UnitTestName := metrotest

#############################
# Automated Testing Details #
#############################

# The relative path to the testing module containing the unit test source.
UnitTestDir := $(TestDir)/unittests

# The relative path to the Google Test module that contains the source
# code and libraries for the Google Test framework.
GTestDir := $(TestDir)/gtest-1.7.0

# All Google Test headers.  Usually you shouldn't change this
# definition.
GTestHeaders = $(GTestDir)/include/gtest/*.h \
               $(GTestDir)/include/gtest/internal/*.h

# Flags passed to the preprocessor.
# Set Google Test's header directory as a system directory, such that
# the compiler doesn't generate warnings in Google Test headers.
GTestFlags := -isystem $(GTestDir)/include $(Include)
GTestFlags += -pthread #-Wall -Wextra

# Builds gtest.a and gtest_main.a.
# Usually you shouldn't tweak such internal variables, indicated by a
# trailing _.
GTEST_SRCS_ = $(GTestDir)/src/*.cc $(GTestDir)/src/*.h $(GTestHeaders)

###########################
# Application Definitions #
###########################

# The base define list to pass to the compiled and linked executable
Definitions := APP_NAME=\"$(AppName)\"

# Check for the BUILD definition being set to debug or release. If this define
# is not set by the user, then the build will default to a release build. If
# the user specifies an option other than 'debug' or 'release' then the build
# will default to release build.
ifeq ($(BUILD),debug)   
	# "Debug" build - set compiling and linking flags
	CxxFlags += $(CxxDebugFlags)
	LFlags += $(CxxDebugFlags)
	CuFlags += $(CuDebugFlags)
	LCuFlags += $(CuDebugFlags)
	AppDir := $(BinDir)/debug
	Definitions += DEBUG
else
	# "Release" build - set compiling and linking flags
	CxxFlags += $(CxxReleaseFlags)
	LFlags += $(CxxReleaseFlags)
	CuFlags += $(CuReleaseFlags)
	LCuFlags += $(CuReleaseFlags)
	AppDir := $(BinDir)
	Definitions += RELEASE
endif

# Check for the PRECISION definition being set to single or double. If this
# define is not set by the user, then the build will default to single
# precision. If the user specifies an option other than 'single' or 'double'
# then the build will default to single precision.
ifeq ($(PRECISION),double)
	Definitions += DOUBLE_PRECISION
else
	Definitions += SINGLE_PRECISION
endif

######################
# Internal Variables #
######################

# Derives the compiler flags for included search paths
Includes := $(addprefix -I,$(IncPaths))

# Derives the compiler flags for defined variables for the application
Defines := $(addprefix -D, $(Definitions))

# Derives the paths to each of the source modules
SourceModules := $(addprefix $(SourceDir)/,$(Modules))

# Derives which source files to include in the testing framework.
TestingInclusions := $(patsubst %,$(ObjDir)/$(SourceDir)/%,$(TestingModules))
TestingFilter := $(addsuffix %,$(TestingInclusions))

# Creates a list of folders inside the object output directory that need
# to be created for the compiled files.
ObjFolders := $(addprefix $(ObjDir)/,$(SourceModules))
ObjFolders += $(ObjDir)/$(UnitTestDir)

# Searches through the specified Modules list for all of the valid
# files that it can find and compile. Once all of the files are 
# found, they are appended with an .o and prefixed with the object
# directory path. This allows the compiled object files to be routed
# to the proper output directory.
Sources := $(filter $(FileTypes),$(wildcard $(addsuffix /*,$(SourceModules))))
Objects := $(patsubst %,$(ObjDir)/%.o,$(basename $(Sources)))

# The unit testing objects are all gathered seperately because they are 
# included all at once from the testing directory and are compiled into the
# output program alongside the source objects.
UnitTestingSources := $(filter $(FileTypes),$(wildcard $(UnitTestDir)/*))
UnitTestingObjects := $(patsubst %,$(ObjDir)/%.o,\
		      $(basename $(UnitTestingSources)))
UnitTestingObjects += $(filter $(TestingFilter),$(Objects))

# This is the directory and matching criteria that the dependency files use
# to figure out if files have been updated or not.
DepDir := $(ObjDir)
DF = $(DepDir)/$*

##############################
# Makefile Rules and Targets #
##############################

# Specifies that these make targets are not actual files and therefore will
# not break if a similar named file exists in the directory.
.PHONY : all $(AppName) $(UnitTestName) directories clean

# The makefile targets:

all : directories $(AppName)

$(AppName) : $(Objects)
	$(NVCC) $^ $(Includes) $(Defines) -o $(AppDir)/$@ $(LCuFlags)

directories :
	@mkdir -p $(ObjDir) $(ObjFolders) $(BinDir) $(AppDir)

clean : 
	rm -rf $(ObjDir) $(BinDir)



# $(AppDir)/$(UnitTestName) : $(Objects) $(ObjDir)/gtest_main.a
#	$(CC) $(GTestFlags) -lpthread $^ -o $@


# For simplicity and to avoid depending on Google Test's
# implementation details, the dependencies specified below are
# conservative and not optimized.  This is fine as Google Test
# compiles fast and for ordinary users its source rarely changes.

$(ObjDir)/gtest-all.o : $(GTEST_SRCS_)
	$(CC) $(GTestFlags) -I$(GTestDir) -c \
            $(GTestDir)/src/gtest-all.cc -o $@

$(ObjDir)/gtest_main.o : $(GTEST_SRCS_)
	$(CC) $(GTestFlags) -I$(GTestDir) -c \
	  $(GTestDir)/src/gtest_main.cc -o $@

$(ObjDir)/gtest.a : $(ObjDir)/gtest-all.o
	$(AR) $(ARFLAGS) $@ $^

$(ObjDir)/gtest_main.a : $(ObjDir)/gtest-all.o $(ObjDir)/gtest_main.o
	$(AR) $(ARFLAGS) $@ $^


# Here are the Rules that determine how to compile a CUDA and a C++ source 
# file into an object file. Also, this rule will generate the file's
# dependecies and format the file into a format that allows for easy and
# effecient dependency resolution. The CUDA code must be compiled twice (once
# for the object file and once for the dependencies), whereas the C++ code
# can accomplish both actions with one compile (by using the -MMD flag).

$(ObjDir)/%.o : %.cu
	$(NVCC) $(Includes) $(Defines) -M $< -o $(ObjDir)/$*.d
	@cp $(DF).d $(DF).dep
	@sed -e 's/#.*//' -e 's/^[^:]*: *//' -e 's/ *\\$$//' \
	    -e '/^$$/ d' -e 's/$$/ :/' < $(DF).d >> $(DF).dep
	@rm -f $(DF).d
	$(NVCC) $(CuFlags) $(Includes) $(Defines) $< -o $@

$(ObjDir)/$(UnitTestDir)/%.o : $(UnitTestDir)/%.cpp $(GTestHeaders)
	g++ $(GTestFlags) -c $< -o $@

$(ObjDir)/%.o : %.cpp
	$(CC) $(CxxFlags) $(Includes) $(Defines) -MMD $< -o $@
	@cp $(DF).d $(DF).dep
	@sed -e 's/#.*//' -e 's/^[^:]*: *//' -e 's/ *\\$$//' \
	    -e '/^$$/ d' -e 's/$$/ :/' < $(DF).d >> $(DF).dep
	@rm -f $(DF).d

######################
# Dependency Include #
######################

# This conditional statement will attempt to include all of the dependency
# files located in the object directory. If the files exist, then their
# dependency information is loaded, and each source file checks to see if
# it needs to be recompiled. The if statements are used to make sure that
# the dependency info isn't rebuilt when the object directory is being
# cleaned.

ifneq ($(MAKECMDGOALS),directories)
ifneq ($(MAKECMDGOALS),clean)
-include $(Objects:.o=.dep)
endif
endif