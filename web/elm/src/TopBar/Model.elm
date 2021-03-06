module TopBar.Model exposing
    ( Dropdown(..)
    , MiddleSection(..)
    , Model
    , PipelineState(..)
    , isPaused
    )

import Concourse
import RemoteData
import Routes
import ScreenSize exposing (ScreenSize)


type alias Model =
    { isUserMenuExpanded : Bool
    , isPinMenuExpanded : Bool
    , middleSection : MiddleSection
    , teams : RemoteData.WebData (List Concourse.Team)
    , screenSize : ScreenSize
    , highDensity : Bool
    }



-- The Route in middle section should always be a pipeline, build, resource, or job, but that's hard to demonstrate statically


type MiddleSection
    = Breadcrumbs Routes.Route
    | MinifiedSearch
    | SearchBar { query : String, dropdown : Dropdown }
    | Empty


type Dropdown
    = Hidden
    | Shown { selectedIdx : Maybe Int }


type PipelineState
    = None
    | HasPipeline
        { pinnedResources : List ( String, Concourse.Version )
        , pipeline : Concourse.PipelineIdentifier
        , isPaused : Bool
        }


isPaused : PipelineState -> Bool
isPaused pipeline =
    case pipeline of
        None ->
            False

        HasPipeline { isPaused } ->
            isPaused
