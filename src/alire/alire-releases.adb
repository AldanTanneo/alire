with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Alire.Config;
with Alire.Crates;
with Alire.Directories;
with Alire.Defaults;
with Alire.Errors;
with Alire.Origins.Deployers;
with Alire.Paths;
with Alire.Properties.Bool;
with Alire.Properties.Actions.Executor;
with Alire.TOML_Load;
with Alire.Utils.YAML;
with Alire.Warnings;

with GNAT.IO; -- To keep preelaborable

with Semantic_Versioning.Basic;
with Semantic_Versioning.Extended;

with TOML.File_IO;

package body Alire.Releases is

   package Semver renames Semantic_Versioning;

   use all type Alire.Properties.Labeled.Labels;

   --------------------
   -- All_Properties --
   --------------------

   function All_Properties (R : Release;
                            P : Alire.Properties.Vector)
                            return Alire.Properties.Vector
   is (Materialize (R.Properties, P));

   ------------------------
   -- Default_Properties --
   ------------------------

   function Default_Properties return Conditional.Properties
   is (Conditional.For_Properties.New_Value
       (New_Label (Description,
                   Defaults.Description)));

   -----------------------
   -- Flat_Dependencies --
   -----------------------

   function Flat_Dependencies
     (R : Release;
      P : Alire.Properties.Vector := Alire.Properties.No_Properties)
      return Alire.Dependencies.Containers.List
   is
      function Enumerate is new Conditional.For_Dependencies.Enumerate
        (Alire.Dependencies.Containers.List,
         Alire.Dependencies.Containers.Append);
   begin
      if P.Is_Empty then
         --  Trying to evaluate a tree with empty dependencies will result
         --  in spurious warnings about missing environment properties (as we
         --  indeed didn't give any). Since we want to get flat dependencies
         --  that do not depend on any properties, this is indeed safe to do.
         return Enumerate (R.Dependencies);
      else
         return Enumerate (R.Dependencies.Evaluate (P));
      end if;
   end Flat_Dependencies;

   -------------------------
   -- Check_Caret_Warning --
   -------------------------
   --  Warn of ^0.x dependencies that probably should be ~0.x
   function Check_Caret_Warning (This : Release) return Boolean is
      use Alire.Utils;
      Newline    : constant String := ASCII.LF & "   ";
   begin
      for Dep of This.Flat_Dependencies loop
         if Config.Get (Config.Keys.Warning_Caret, Default => True) and then
           Utils.Contains (Dep.Versions.Image, "^0")
         then
            Warnings.Warn_Once
              ("Possible tilde intended instead of caret for a 0.x version."
               & Newline
               & "Alire does not change the meaning of caret and tilde"
               & " for pre/post-1.0 versions."
               & Newline
               & "The suspicious dependency is: " & TTY.Version (Dep.Image)
               & Newline
               & "You can disable this warning by setting the option "
               & TTY.Emph (Config.Keys.Warning_Caret) & " to false.",
               Warnings.Caret_Or_Tilde);
            return True;
         end if;
      end loop;

      return False;
   end Check_Caret_Warning;

   -------------------
   -- Dependency_On --
   -------------------

   function Dependency_On (R     : Release;
                           Crate : Crate_Name;
                           P     : Alire.Properties.Vector :=
                             Alire.Properties.No_Properties)
                           return Alire.Dependencies.Containers.Optional
   is
   begin
      for Dep of R.Flat_Dependencies (P) loop
         if Dep.Crate = Crate then
            return Alire.Dependencies.Containers.Optionals.Unit (Dep);
         end if;
      end loop;

      return Alire.Dependencies.Containers.Optionals.Empty;
   end Dependency_On;

   ------------
   -- Deploy --
   ------------

   procedure Deploy
     (This            : Alire.Releases.Release;
      Env             : Alire.Properties.Vector;
      Parent_Folder   : String;
      Was_There       : out Boolean;
      Perform_Actions : Boolean := True;
      Create_Manifest : Boolean := False;
      Include_Origin  : Boolean := False)
   is
      use Alire.Directories;
      use all type Alire.Properties.Actions.Moments;
      Folder : constant Any_Path := Parent_Folder / This.Unique_Folder;
      Result : Alire.Outcome;

      ------------------------------
      -- Backup_Upstream_Manifest --
      ------------------------------

      procedure Backup_Upstream_Manifest is
         Working_Dir : Guard (Enter (Folder)) with Unreferenced;
      begin
         Ada.Directories.Create_Path (Paths.Working_Folder_Inside_Root);

         if GNAT.OS_Lib.Is_Regular_File (Paths.Crate_File_Name) then
            Trace.Debug ("Backing up bundled manifest file as *.upstream");
            declare
               Upstream_File : constant String :=
                                 Paths.Working_Folder_Inside_Root
                                 / (Paths.Crate_File_Name & ".upstream");
            begin
               Alire.Directories.Backup_If_Existing
                 (Upstream_File,
                  Base_Dir => Paths.Working_Folder_Inside_Root);
               Ada.Directories.Rename
                 (Old_Name => Paths.Crate_File_Name,
                  New_Name => Upstream_File);
            end;
         end if;
      end Backup_Upstream_Manifest;

      -----------------------------------
      -- Create_Authoritative_Manifest --
      -----------------------------------

      procedure Create_Authoritative_Manifest (Kind : Manifest.Sources) is
      begin
         Trace.Debug ("Generating manifest file for "
                      & This.Milestone.TTY_Image & " with"
                      & This.Dependencies.Leaf_Count'Img & " dependencies");

         This.Whenever (Env).To_File (Folder / Paths.Crate_File_Name,
                                      Kind);
      end Create_Authoritative_Manifest;

   begin

      --  Deploy if the target dir is not already there

      if Ada.Directories.Exists (Folder) then
         Was_There := True;
         Trace.Detail ("Skipping checkout of already available " &
                         This.Milestone.Image);
      else
         Was_There := False;
         Put_Info ("Deploying release " & This.Milestone.TTY_Image & " ...");
         Result := Alire.Origins.Deployers.Deploy (This, Folder);
         if not Result.Success then
            Raise_Checked_Error (Message (Result));
         end if;

         --  For deployers that do nothing, we ensure the folder exists so all
         --  dependencies leave a trace in the cache/dependencies folder, and
         --  a place from where to run their actions by default.

         Ada.Directories.Create_Path (Folder);

         --  Backup a potentially packaged manifest, so our authoritative
         --  manifest from the index is always used.

         Backup_Upstream_Manifest;

         if Create_Manifest then
            Create_Authoritative_Manifest (if Include_Origin
                                           then Manifest.Index
                                           else Manifest.Local);
         end if;
      end if;

      --  Run actions on first retrieval

      if Perform_Actions and then not Was_There then
         declare
            Work_Dir : Guard (Enter (Folder)) with Unreferenced;
         begin
            Alire.Properties.Actions.Executor.Execute_Actions
              (Release => This,
               Env     => Env,
               Moment  => Post_Fetch);
         end;
      end if;
   end Deploy;

   ----------------
   -- Forbidding --
   ----------------

   function Forbidding (Base      : Release;
                        Forbidden : Conditional.Forbidden_Dependencies)
                        return Release is
   begin
      return Extended : Release := Base do
         Extended.Forbidden := Forbidden;
      end return;
   end Forbidding;

   --------------
   -- Renaming --
   --------------

   function Renaming (Base     : Release;
                      Provides : Crate_Name) return Release is
   begin
      return Renamed : Release := Base do
         Renamed.Alias := +(+Provides);
      end return;
   end Renaming;

   ---------------
   -- Replacing --
   ---------------

   function Replacing (Base   : Release;
                       Origin : Origins.Origin) return Release is
   begin
      return Replaced : Release := Base do
         Replaced.Origin := Origin;
      end return;
   end Replacing;

   ---------------
   -- Replacing --
   ---------------

   function Replacing
     (Base         : Release;
      Dependencies : Conditional.Dependencies := Conditional.No_Dependencies)
      return Release is
   begin
      return Replaced : Release := Base do
         Replaced.Dependencies := Dependencies;
      end return;
   end Replacing;

   ---------------
   -- Replacing --
   ---------------

   function Replacing
     (Base         : Release;
      Properties   : Conditional.Properties   := Conditional.No_Properties)
      return Release is
   begin
      return Replaced : Release := Base do
         Replaced.Properties := Properties;
      end return;
   end Replacing;

   ---------------
   -- Replacing --
   ---------------

   function Replacing
     (Base               : Release;
      Notes              : Description_String := "")
      return Release
   is
      New_Notes   : constant Description_String := (if Notes = ""
                                                    then Base.Notes
                                                    else Notes);
   begin

      return Replacement : constant Release
        (Base.Name.Length, New_Notes'Length) :=
        (Prj_Len   => Base.Name.Length,
         Notes_Len => New_Notes'Length,
         Name      => Base.Name,
         Notes     => New_Notes,

         Alias        => Base.Alias,
         Version      => Base.Version,
         Origin       => Base.Origin,
         Dependencies => Base.Dependencies,
         Pins         => Base.Pins,
         Forbidden    => Base.Forbidden,
         Properties   => Base.Properties,
         Available    => Base.Available)
      do
         null;
      end return;
   end Replacing;

   ---------------
   -- Retagging --
   ---------------

   function Retagging (Base    : Release;
                       Version : Semantic_Versioning.Version) return Release is
   begin
      return Upgraded : Release := Base do
         Upgraded.Version := Version;
      end return;
   end Retagging;

   ---------------
   -- Upgrading --
   ---------------

   function Upgrading (Base    : Release;
                       Version : Semantic_Versioning.Version;
                       Origin  : Origins.Origin) return Release is
   begin
      return Upgraded : Release := Base do
         Upgraded.Version := Version;
         Upgraded.Origin  := Origin;
      end return;
   end Upgrading;

   -----------------
   -- New_Release --
   -----------------

   function New_Release (Name         : Crate_Name;
                         Version      : Semantic_Versioning.Version;
                         Origin       : Origins.Origin;
                         Notes        : Description_String;
                         Dependencies : Conditional.Dependencies;
                         Properties   : Conditional.Properties;
                         Available    : Conditional.Availability)
                         return Release
   is (Prj_Len      => Name.Length,
       Notes_Len    => Notes'Length,
       Name         => Name,
       Alias        => +"",
       Version      => Version,
       Origin       => Origin,
       Notes        => Notes,
       Dependencies => Dependencies,
       Pins         => <>,
       Forbidden    => Conditional.For_Dependencies.Empty,
       Properties   => Properties,
       Available    => Available);

   -----------------------
   -- New_Empty_Release --
   -----------------------

   function New_Empty_Release (Name : Crate_Name) return Release
   is (New_Working_Release (Name         => Name,
                            Properties   => Conditional.No_Properties));

   -------------------------
   -- New_Working_Release --
   -------------------------

   function New_Working_Release
     (Name         : Crate_Name;
      Origin       : Origins.Origin           := Origins.New_Filesystem (".");
      Dependencies : Conditional.Dependencies :=
        Conditional.For_Dependencies.Empty;
      Properties   : Conditional.Properties   :=
        Default_Properties)
      return         Release is
     (Prj_Len      => Name.Length,
      Notes_Len    => 0,
      Name         => Name,
      Alias        => +"",
      Version      => +"0.0.0",
      Origin       => Origin,
      Notes        => "",
      Dependencies => Dependencies,
      Pins         => <>,
      Forbidden    => Conditional.For_Dependencies.Empty,
      Properties   => Properties,
      Available    => Conditional.Empty
     );

   -------------------------
   -- On_Platform_Actions --
   -------------------------

   function On_Platform_Actions (R : Release;
                                 P : Alire.Properties.Vector;
                                 Moments : Moment_Array := (others => True))
                                 return Alire.Properties.Vector
   is
      use Alire.Properties.Actions;
   begin
      return Filtered : Alire.Properties.Vector do
         for Prop of R.On_Platform_Properties
           (P, Alire.Properties.Actions.Action'Tag)
         loop
            if Moments (Action'Class (Prop).Moment) then
               Filtered.Append (Prop);
            end if;
         end loop;
      end return;
   end On_Platform_Actions;

   ----------------------------
   -- On_Platform_Properties --
   ----------------------------

   function On_Platform_Properties
     (R             : Release;
      P             : Alire.Properties.Vector;
      Descendant_Of : Ada.Tags.Tag := Ada.Tags.No_Tag)
      return Alire.Properties.Vector
   is
      use Ada.Tags;
   begin
      if Descendant_Of = No_Tag then
         return Materialize (R.Properties, P);
      else
         declare
            Props : constant Alire.Properties.Vector :=
              R.On_Platform_Properties (P);
         begin
            return Result : Alire.Properties.Vector do
               for P of Props loop
                  if Is_Descendant_At_Same_Level (P'Tag, Descendant_Of) then
                     Result.Append (P);
                  end if;
               end loop;
            end return;
         end;
      end if;
   end On_Platform_Properties;

   ----------------------
   -- Props_To_Strings --
   ----------------------

   function Props_To_Strings (Props : Alire.Properties.Vector;
                    Label : Alire.Properties.Labeled.Labels)
                    return Utils.String_Vector is
      --  Extract values of a particular label
      Filtered : constant Alire.Properties.Vector :=
                   Alire.Properties.Labeled.Filter (Props, Label);
   begin
      return Strs : Utils.String_Vector do
         for P of Filtered loop
            Strs.Append (Alire.Properties.Labeled.Label (P).Value);
         end loop;
      end return;
   end Props_To_Strings;

   -----------------
   -- Environment --
   -----------------

   function Environment (R : Release;
                         P : Alire.Properties.Vector) return Env_Maps.Map
   is
      package Env renames Alire.Properties.Environment;
   begin
      return Map : Env_Maps.Map do
         for Prop of R.On_Platform_Properties (P, Env.Variable'Tag) loop
            Map.Insert (Env.Variable (Prop).Name,
                        Env.Variable (Prop));
         end loop;
      end return;
   end Environment;

   -----------------
   -- Executables --
   ----------------

   function Executables (R : Release;
                         P : Alire.Properties.Vector)
                         return Utils.String_Vector
   is
      Exes : constant Utils.String_Vector :=
        Props_To_Strings (R.All_Properties (P), Executable);
   begin
      if OS_Lib.Exe_Suffix /= "" then
         declare
            With_Suffix : Utils.String_Vector;
         begin
            for I in Exes.Iterate loop
               With_Suffix.Append (Exes (I) & OS_Lib.Exe_Suffix);
            end loop;
            return With_Suffix;
         end;
      end if;
      return Exes;
   end Executables;

   -------------------
   -- Project_Files --
   -------------------

   function Project_Files (R         : Release;
                           P         : Alire.Properties.Vector;
                           With_Path : Boolean)
                           return Utils.String_Vector
   is
      use Utils;

      With_Paths : Utils.String_Vector :=
        Props_To_Strings (R.All_Properties (P), Project_File);
      Without    : Utils.String_Vector;
   begin
      if With_Paths.Is_Empty
        and then
         R.Origin.Kind not in Origins.External | Origins.System
      then
         --  Default project file if no one is specified by the crate. Only if
         --  the create is not external nor system.
         With_Paths.Append (String'((+R.Name) & ".gpr"));
      end if;

      if With_Path then
         return With_Paths;
      else
         for File of With_Paths loop

            --  Basename
            Without.Append (Split (Text => File,
                                   Separator => '/',
                                   Side      => Tail,
                                   From      => Tail,
                                   Raises    => False));

         end loop;

         return Without;
      end if;
   end Project_Files;

   -------------------
   -- Project_Paths --
   -------------------

   function Project_Paths (R         : Release;
                           P         : Alire.Properties.Vector)
                           return      Utils.String_Set
   is
      use Utils;
      use Ada.Strings;
      Files : constant String_Vector :=
        Project_Files (R, P, With_Path => True);
   begin
      return Paths : String_Set do
         for File of Files loop
            if Contains (File, "/") then
               Paths.Include
                 (File (File'First .. Fixed.Index (File, "/", Backward)));
            else

               --  The project file is at the root of the release
               Paths.Include ("");
            end if;
         end loop;
      end return;
   end Project_Paths;

   -------------------
   -- Auto_GPR_With --
   -------------------

   function Auto_GPR_With (R : Release) return Boolean is
      Vect : constant Alire.Properties.Vector :=
        Conditional.Enumerate (R.Properties).Filter
        (Alire.TOML_Keys.Auto_GPR_With);
   begin
      if not Vect.Is_Empty then
         return Alire.Properties.Bool.Property (Vect.First_Element).Value;
      else
         --  The default is to enable auto-gpr-with
         return True;
      end if;
   end Auto_GPR_With;

   ------------------
   -- Has_Property --
   ------------------

   function Has_Property (R : Release; Key : String) return Boolean
   is (for some Prop of Conditional.Enumerate (R.Properties) =>
          Prop.Key = Utils.To_Lower_Case (Key));

   ------------------------
   -- Labeled_Properties --
   ------------------------

   function Labeled_Properties_Vector (R     : Release;
                                       P     : Alire.Properties.Vector;
                                       Label : Alire.Properties.Labeled.Labels)
                                       return Alire.Properties.Vector is
   begin
      return Alire.Properties.Labeled.Filter (R.All_Properties (P), Label);
   end Labeled_Properties_Vector;

   ------------------------
   -- Labeled_Properties --
   ------------------------

   function Labeled_Properties (R     : Release;
                                P     : Alire.Properties.Vector;
                                Label : Alire.Properties.Labeled.Labels)
                                return Utils.String_Vector
   is
   begin
      return Props_To_Strings (R.All_Properties (P), Label);
   end Labeled_Properties;

   -----------
   -- Print --
   -----------

   procedure Print (R : Release) is
      use GNAT.IO;
   begin
      --  MILESTONE
      Put_Line (R.Milestone.TTY_Image & ": " & R.TTY_Description);

      if R.Provides /= R.Name then
         Put_Line ("Provides: " & (+R.Provides));
      end if;

      if R.Notes /= "" then
         Put_Line ("Notes: " & R.Notes);
      end if;

      --  ORIGIN
      Put_Line ("Origin: " & R.Origin.Image);

      --  AVAILABILITY
      if not R.Available.Is_Empty then
         Put_Line ("Available when: " & R.Available.Image_One_Line);
      end if;

      --  PROPERTIES
      if not R.Properties.Is_Empty then
         Put_Line ("Properties:");
         R.Properties.Print ("   ",
                             And_Or  => False,
                             Verbose => Alire.Log_Level >= Detail);
      end if;

      --  DEPENDENCIES
      if not R.Dependencies.Is_Empty then
         Put_Line ("Dependencies (direct):");
         R.Dependencies.Print ("   ",
                               Sorted => True,
                               And_Or => R.Dependencies.Contains_ORs);
      end if;
   end Print;

   --------------
   -- Property --
   --------------

   function Property (R   : Release;
                      Key : Alire.Properties.Labeled.Labels)
                      return String
   is
      use Alire.Properties.Labeled;
      Target : constant Alire.Properties.Vector :=
                 Filter (R.Properties, Key);
   begin
      if Target.Length not in 1 then
         raise Constraint_Error with
           "Unexpected property count:" & Target.Length'Img;
      end if;

      return Label (Target.First_Element).Value;
   end Property;

   -----------------------
   -- Property_Contains --
   -----------------------

   function Property_Contains (R : Release; Str : String) return Boolean is
      use Utils;

      Search : constant String := To_Lower_Case (Str);
   begin
      for P of Conditional.Enumerate (R.Properties) loop
         declare
            Text : constant String :=
                     To_Lower_Case
                       ((if Utils.Contains (P.Image, ":")
                        then Utils.Tail (P.Image, ':')
                        else P.Image));
         begin
            if Utils.Contains (Text, Search) then
               return True;
            end if;
         end;
      end loop;

      return False;
   end Property_Contains;

   -------------------
   -- From_Manifest --
   -------------------

   function From_Manifest (File_Name : Any_Path;
                           Source    : Manifest.Sources;
                           Strict    : Boolean)
                           return Release
   is
   begin
      return From_TOML
        (TOML_Adapters.From
           (TOML_Load.Load_File (File_Name),
            "Loading release from manifest: " & File_Name),
         Source,
         Strict,
         File_Name);
   exception
      when E : others =>
         Log_Exception (E);
         --  As this file is edited manually, it may not load for many reasons
         Raise_Checked_Error (Errors.Wrap ("Failed to load " & File_Name,
                                           Errors.Get (E)));
   end From_Manifest;

   ---------------
   -- From_TOML --
   ---------------

   function From_TOML (From   : TOML_Adapters.Key_Queue;
                       Source : Manifest.Sources;
                       Strict : Boolean;
                       File   : Any_Path := "")
                       return Release is
   begin
      From.Assert_Key (TOML_Keys.Name, TOML.TOML_String);

      return This : Release := New_Empty_Release
        (Name => +From.Unwrap.Get (TOML_Keys.Name).As_String)
      do
         Assert (This.From_TOML (From, Source, Strict, File));
      end return;
   end From_TOML;

   ---------------
   -- From_TOML --
   ---------------

   function From_TOML (This   : in out Release;
                       From   :        TOML_Adapters.Key_Queue;
                       Source :        Manifest.Sources;
                       Strict :        Boolean;
                       File   :        Any_Path := "")
                       return Outcome
   is
      package Dirs    renames Ada.Directories;
      package Labeled renames Alire.Properties.Labeled;
   begin
      Trace.Debug ("Loading release " & This.Milestone.Image);

      --  Origin

      case Source is
         when Manifest.Index =>
            This.Origin.From_TOML (From).Assert;
         when Manifest.Local =>
            This.Origin :=
              Origins.New_Filesystem
                (Dirs.Containing_Directory   -- same folder as manifest file's
                   (Dirs.Full_Name (File))); -- absolute path
            --  We don't require an origin for a local release, as the release
            --  is already in place.
      end case;

      --  Properties

      TOML_Load.Load_Crate_Section
        (Strict  => Strict or else Source in Manifest.Local,
         Section => (case Source is
                        when Manifest.Index => Crates.Index_Release,
                        when Manifest.Local => Crates.Local_Release),
         From    => From,
         Props   => This.Properties,
         Deps    => This.Dependencies,
         Pins    => This.Pins,
         Avail   => This.Available);

      --  Consolidate/validate some properties as fields:

      Assert (This.Name_Str = This.Property (Labeled.Name),
              "Mismatched name property and given name at release creation");

      This.Version := Semver.New_Version (This.Property (Labeled.Version));

      --  Check for remaining keys, which must be erroneous:
      return From.Report_Extra_Keys;
   end From_TOML;

   -------------------
   -- To_Dependency --
   -------------------

   function To_Dependency (R : Release) return Conditional.Dependencies is
     (Conditional.For_Dependencies.New_Value
        (Alire.Dependencies.New_Dependency
             (R.Name,
              Semver.Extended.To_Extended
                (Semver.Basic.Exactly (R.Version)))));

   -------------
   -- To_File --
   -------------

   procedure To_File (R        : Release;
                      Filename : String;
                      Format   : Manifest.Sources) is
      use Ada.Text_IO;
      File : File_Type;
   begin
      Create (File, Out_File, Filename);
      TOML.File_IO.Dump_To_File (R.To_TOML (Format), File);
      Close (File);
   exception
      when others =>
         if Is_Open (File) then
            Close (File);
         end if;
         raise;
   end To_File;

   -------------
   -- To_TOML --
   -------------

   function To_TOML (R      : Release;
                     Format : Manifest.Sources)
                     return TOML.TOML_Value
   is
      package APL renames Alire.Properties.Labeled;
      use all type Alire.Properties.Labeled.Cardinalities;
      use TOML_Adapters;
      Root : constant TOML.TOML_Value := R.Properties.To_TOML;
   begin

      --  Name
      Root.Set (TOML_Keys.Name, +R.Name_Str);

      --  Version
      Root.Set (TOML_Keys.Version, +Semver.Image (R.Version));

      --  Alias/Provides
      if UStrings.Length (R.Alias) > 0 then
         Root.Set (TOML_Keys.Provides, +(+R.Alias));
      end if;

      --  Notes
      if R.Notes'Length > 0 then
         Root.Set (TOML_Keys.Notes, +R.Notes);
      end if;

      --  Ensure atoms are atoms and arrays are arrays
      for Label in APL.Cardinality'Range loop
         if Root.Has (APL.Key (Label)) then
            case APL.Cardinality (Label) is
               when Unique   =>
                  pragma Assert
                    (Root.Get
                       (APL.Key (Label)).Kind in TOML.Atom_Value_Kind);
               when Multiple =>
                  Root.Set
                    (APL.Key (Label),
                     TOML_Adapters.To_Array
                       (Root.Get (APL.Key (Label))));
            end case;
         end if;
      end loop;

      --  Origin
      case Format is
         when Manifest.Index =>
            Root.Set (TOML_Keys.Origin, R.Origin.To_TOML);
         when Manifest.Local =>
            null;
      end case;

      --  Dependencies, wrapped as an array
      if not R.Dependencies.Is_Empty then
         declare
            Dep_Array : constant TOML.TOML_Value := TOML.Create_Array;
         begin
            Dep_Array.Append (R.Dependencies.To_TOML);
            Root.Set (TOML_Keys.Depends_On, Dep_Array);
         end;
      end if;

      --  Forbidden
      if not R.Forbidden.Is_Empty then
         Root.Set (TOML_Keys.Forbidden, R.Forbidden.To_TOML);
      end if;

      --  Available
      if R.Available.Is_Empty or else
         R.Available.Value.Is_Available
      then
         null; -- Do nothing, do not pollute .toml file
      else
         Root.Set (TOML_Keys.Available, R.Available.To_TOML);
      end if;

      return Root;
   end To_TOML;

   -------------
   -- To_YAML --
   -------------

   overriding
   function To_YAML (R : Release) return String is

      function Props_To_YAML
      is new Utils.YAML.To_YAML (Alire.Properties.Property'Class,
                                 Alire.Properties.Vectors,
                                 Alire.Properties.Vector);

   begin
      return
        "crate: " & Utils.YAML.YAML_Stringify (R.Name_Str) & ASCII.LF &
        "authors: " & Props_To_YAML (R.Author) & ASCII.LF &
        "maintainers: " & Props_To_YAML (R.Maintainer) & ASCII.LF &
        "licenses: " & Props_To_YAML (R.License) & ASCII.LF &
        "websites: " & Props_To_YAML (R.Website) & ASCII.LF &
        "tags: " & Props_To_YAML (R.Tag) & ASCII.LF &
        "version: " & Utils.YAML.YAML_Stringify (R.Version_Image) & ASCII.LF &
        "short_description: " & Utils.YAML.YAML_Stringify (R.Description) &
        ASCII.LF &
        "dependencies: " & R.Dependencies.To_YAML & ASCII.LF &
        "configuration_variables: " &
           Props_To_YAML (R.Config_Variables) & ASCII.LF &
        "configuration_values: " &
           Props_To_YAML (R.Config_Settings) & ASCII.LF;
   end To_YAML;

   -------------
   -- Version --
   -------------

   function Version (R : Release) return Semantic_Versioning.Version is
     (R.Version);

   --------------
   -- Whenever --
   --------------

   function Whenever (R : Release;
                      P : Alire.Properties.Vector)
                      return Release
   is (Prj_Len      => R.Prj_Len,
       Notes_Len    => R.Notes_Len,
       Name         => R.Name,
       Alias        => R.Alias,
       Version      => R.Version,
       Origin       => R.Origin.Whenever (P),
       Notes        => R.Notes,
       Dependencies => R.Dependencies.Evaluate (P),
       Pins         => R.Pins,
       Forbidden    => R.Forbidden.Evaluate (P),
       Properties   => R.Properties.Evaluate (P),
       Available    => R.Available.Evaluate (P));

   ----------------------
   -- Long_Description --
   ----------------------

   function Long_Description (R : Release) return String is
      Descr : constant Alire.Properties.Vector :=
        Conditional.Enumerate (R.Properties).Filter
        (Alire.TOML_Keys.Long_Descr);
   begin
      if not Descr.Is_Empty then
         --  Image returns "Description: Blah" so we have to cut.
         return Utils.Tail (Descr.First_Element.Image, ' ');
      else
         return "";
      end if;
   end Long_Description;

end Alire.Releases;
