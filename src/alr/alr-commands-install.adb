with AAA.Table_IO;

with Alire.Config.Edit;
with Alire.Containers;
with Alire.Dependencies;
with Alire.Errors;
with Alire.Milestones;
with Alire.Releases;
with Alire.Shared;
with Alire.Solver;
with Alire.Toolchains;
with Alire.Utils;

with Semantic_Versioning.Extended;

package body Alr.Commands.Install is

   --------------------
   -- Setup_Switches --
   --------------------

   overriding
   procedure Setup_Switches
     (Cmd    : in out Command;
      Config : in out GNAT.Command_Line.Command_Line_Configuration)
   is
      use GNAT.Command_Line;
   begin
      Define_Switch
        (Config,
         Cmd.Toolchain'Access,
         Switch      => "",
         Long_Switch => "--toolchain",
         Help        => "Run the toolchain selection assistant");

      Define_Switch
        (Config,
         Cmd.Uninstall'Access,
         Switch      => "-u",
         Long_Switch => "--uninstall",
         Help        => "Uninstall a release");
   end Setup_Switches;

   -------------
   -- Install --
   -------------

   procedure Install (Cmd : in out Command; Request : String) is
      use Alire;
   begin
      Cmd.Requires_Full_Index;

      Installation :
      declare
         Dep : constant Dependencies.Dependency :=
                 Dependencies.From_String (Request);
         Rel : constant Releases.Release :=
                 Solver.Find (Name    => Dep.Crate,
                              Allowed => Dep.Versions,
                              Policy  => Query_Policy);
      begin

         --  Inform of how the requested crate has been narrowed down

         if not Alire.Utils.Starts_With (Dep.Versions.Image, "=") then
            Put_Info ("Requested crate resolved as "
                      & Rel.Milestone.TTY_Image);
         end if;

         --  And perform the actual installation

         Shared.Share (Rel);

      end Installation;

   exception
      when E : Alire.Query_Unsuccessful =>
         Alire.Log_Exception (E);
         Trace.Error (Alire.Errors.Get (E));
   end Install;

   ----------
   -- List --
   ----------

   procedure List (Unused_Cmd : in out Command) is
      Table : AAA.Table_IO.Table;
   begin
      if Alire.Shared.Available.Is_Empty then
         Trace.Info ("Nothing installed in configuration prefix "
                     & TTY.URL (Alire.Config.Edit.Path));
         return;
      end if;

      Table.Append (TTY.Emph ("CRATE")).Append (TTY.Emph ("VERSION")).New_Row;

      for Dep of Alire.Shared.Available loop
         Table
           .Append (TTY.Name (Dep.Name))
           .Append (TTY.Version (Dep.Version.Image))
           .New_Row;
      end loop;

      Table.Print;
   end List;

   ---------------
   -- Uninstall --
   ---------------

   procedure Uninstall (Cmd : in out Command; Target : String) is

      ------------------
      -- Find_Version --
      ------------------

      function Find_Version return String is
         --  Obtain all installed releases for the crate; we will proceed if
         --  only one exists.
         Available : constant Alire.Containers.Release_Set :=
                       Alire.Shared.Available.Satisfying
                         (Alire.Dependencies.New_Dependency
                            (Crate    => Alire.To_Name (Target),
                             Versions => Semantic_Versioning.Extended.Any));
      begin
         if Available.Is_Empty then
            Reportaise_Command_Failed
              ("Requested crate has no installed releases: "
               & TTY.Name (Target));
         elsif Available.Length not in 1 then
            Reportaise_Command_Failed
              ("Requested crate has several installed releases, "
               & "please provide an exact target version");
         end if;

         return Available.First_Element.Milestone.Version.Image;
      end Find_Version;

   begin

      --  If no version was given, find if only one is installed

      if not Utils.Contains (Target, "=") then
         Uninstall (Cmd, Target & "=" & Find_Version);
         return;
      end if;

      --  Otherwise we proceed with a complete milestone

      Alire.Shared.Remove (Alire.Milestones.New_Milestone (Target));

   end Uninstall;

   -------------
   -- Execute --
   -------------

   overriding
   procedure Execute (Cmd : in out Command) is
   begin

      --  Validation

      if Cmd.Uninstall and then Cmd.Toolchain then
         Reportaise_Wrong_Arguments
           ("The provided switches cannot be used simultaneously");
      end if;

      if Num_Arguments > 1 then
         Reportaise_Wrong_Arguments
           ("One crate with optional version expected: crate[version set]");
      end if;

      if Cmd.Uninstall and then Num_Arguments /= 1 then
         Reportaise_Wrong_Arguments ("No release to uninstall specified");
      end if;

      if Cmd.Toolchain and then Num_Arguments /= 0 then
         Reportaise_Wrong_Arguments
           ("Toolchain installation does not accept any arguments");
      end if;

      --  Dispatch to subcommands

      if Cmd.Toolchain then
         Cmd.Requires_Full_Index;
         Alire.Toolchains.Assistant;
      elsif Cmd.Uninstall then
         Uninstall (Cmd, Argument (1));
      elsif Num_Arguments = 1 then
         Cmd.Install (Argument (1));
      else
         Cmd.List;
      end if;

   exception
      when E : Semantic_Versioning.Malformed_Input =>
         Alire.Log_Exception (E);
         Reportaise_Wrong_Arguments ("Improper version specification");
   end Execute;

end Alr.Commands.Install;
